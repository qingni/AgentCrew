import Foundation

enum TemplateResolutionPolicy: Sendable {
    case strict
    case lenient
}

struct RunContextBudget: Sendable {
    var maxSummaryChars: Int
    var maxDecisionItems: Int
    var maxDecisionItemChars: Int
    var maxArtifactItems: Int
    var maxArtifactChars: Int
    var maxTailChars: Int
    var maxInjectedCharsPerReference: Int
    var maxPromptInjectionChars: Int
    var maxRunStoreChars: Int
    var maxMirrorFileChars: Int

    static let `default` = RunContextBudget(
        maxSummaryChars: 800,
        maxDecisionItems: 6,
        maxDecisionItemChars: 160,
        maxArtifactItems: 10,
        maxArtifactChars: 180,
        maxTailChars: 2_000,
        maxInjectedCharsPerReference: 2_000,
        maxPromptInjectionChars: 12_000,
        maxRunStoreChars: 120_000,
        maxMirrorFileChars: 200_000
    )
}

actor RunContextStore {
    enum ContextError: LocalizedError {
        case invalidReference(String)
        case unresolvedStepReference(String)
        case ambiguousStepReference(String)
        case inaccessibleStepReference(String)
        case unresolvedField(String)
        case unsupportedExpression(String)

        var errorDescription: String? {
            switch self {
            case .invalidReference(let expression):
                return "Invalid template reference: \(expression)"
            case .unresolvedStepReference(let reference):
                return "Step reference \"\(reference)\" could not be resolved."
            case .ambiguousStepReference(let reference):
                return "Step reference \"\(reference)\" is ambiguous. Use the step UUID."
            case .inaccessibleStepReference(let reference):
                return "Step reference \"\(reference)\" is outside dependency scope."
            case .unresolvedField(let message):
                return message
            case .unsupportedExpression(let expression):
                return "Unsupported template expression: \(expression)"
            }
        }
    }

    private struct StepContextEntry: Sendable {
        let stepID: UUID
        let stepName: String
        let stageID: UUID
        var status: StepStatus = .pending
        var exitCode: Int32?
        var summary: String = ""
        var decisions: [String] = []
        var artifacts: [String] = []
        var outputTail: String = ""
        var errorTail: String = ""
        var finishedAt: Date?
    }

    private let budget: RunContextBudget
    private let resolutionPolicy: TemplateResolutionPolicy
    private let workingDirectory: String
    private let stepOrder: [UUID]
    private let dependencyClosureByStepID: [UUID: Set<UUID>]
    private let stepIDsByNormalizedName: [String: [UUID]]

    private var entries: [UUID: StepContextEntry]
    private var isDirty = false

    init(
        steps: [ResolvedStep],
        workingDirectory: String,
        budget: RunContextBudget = .default,
        resolutionPolicy: TemplateResolutionPolicy = .strict
    ) {
        self.budget = budget
        self.resolutionPolicy = resolutionPolicy
        self.workingDirectory = workingDirectory
        self.stepOrder = steps.map { $0.step.id }
        self.dependencyClosureByStepID = Self.buildDependencyClosure(from: steps)

        var nameIndex: [String: [UUID]] = [:]
        var entries: [UUID: StepContextEntry] = [:]
        entries.reserveCapacity(steps.count)

        for resolved in steps {
            let step = resolved.step
            let normalizedName = Self.normalizedReference(step.name)
            nameIndex[normalizedName, default: []].append(step.id)
            entries[step.id] = StepContextEntry(stepID: step.id, stepName: step.name, stageID: resolved.stageID)
        }

        self.stepIDsByNormalizedName = nameIndex
        self.entries = entries
    }

    func renderPrompt(for step: PipelineStep) throws -> String {
        let template = step.prompt
        guard template.contains("{{"), template.contains("}}") else {
            return template
        }

        let regex = try NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        let templateNSString = template as NSString
        let matches = regex.matches(
            in: template,
            options: [],
            range: NSRange(location: 0, length: templateNSString.length)
        )
        guard !matches.isEmpty else { return template }

        var rendered = ""
        var cursor = 0
        var remainingBudget = budget.maxPromptInjectionChars
        let allowedDependencies = dependencyClosureByStepID[step.id] ?? []

        for match in matches {
            let fullRange = match.range(at: 0)
            let expressionRange = match.range(at: 1)

            if fullRange.location > cursor {
                rendered += templateNSString.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }

            let rawExpression = templateNSString.substring(with: expressionRange)
            let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)

            if !Self.isSupportedExpression(expression) {
                rendered += templateNSString.substring(with: fullRange)
                cursor = fullRange.location + fullRange.length
                continue
            }

            let resolvedValue: String
            do {
                resolvedValue = try resolveExpression(
                    expression,
                    currentStepID: step.id,
                    allowedDependencies: allowedDependencies
                )
            } catch {
                if resolutionPolicy == .strict {
                    throw error
                }
                resolvedValue = "[unresolved context: \(expression)]"
            }
            let clippedValue = clipInjectedValue(resolvedValue, remainingBudget: &remainingBudget)
            rendered += clippedValue
            cursor = fullRange.location + fullRange.length
        }

        if cursor < templateNSString.length {
            rendered += templateNSString.substring(from: cursor)
        }
        return rendered
    }

    func markStatus(stepID: UUID, status: StepStatus) {
        guard var entry = entries[stepID] else { return }
        entry.status = status
        if status == .completed || status == .failed || status == .skipped {
            entry.finishedAt = entry.finishedAt ?? Date()
        }
        entries[stepID] = entry
        isDirty = true
    }

    func recordResult(stepID: UUID, result: StepResult) {
        guard var entry = entries[stepID] else { return }
        entry.exitCode = result.exitCode
        entry.outputTail = Self.trimmedTail(of: result.output, maxChars: budget.maxTailChars)
        entry.errorTail = Self.trimmedTail(of: result.error, maxChars: budget.maxTailChars)
        entry.summary = Self.buildSummary(for: result, maxChars: budget.maxSummaryChars)
        entry.decisions = Self.extractDecisions(
            from: result,
            maxItems: budget.maxDecisionItems,
            maxCharsPerItem: budget.maxDecisionItemChars
        )
        entry.artifacts = Self.extractArtifacts(
            from: result,
            maxItems: budget.maxArtifactItems,
            maxCharsPerItem: budget.maxArtifactChars
        )
        entries[stepID] = entry
        enforceRunStoreBudgetIfNeeded()
        isDirty = true
    }

    func writeMirrorFileIfNeeded(force: Bool = false) {
        guard force || isDirty else { return }
        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkingDirectory.isEmpty else { return }

        let mirrorContent = clippedMirrorContent(renderMirrorContent())
        let rootURL = URL(fileURLWithPath: trimmedWorkingDirectory, isDirectory: true)
        let contextDirectoryURL = rootURL.appendingPathComponent(".agentcrew", isDirectory: true)
        let contextFileURL = contextDirectoryURL.appendingPathComponent("context.md", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: contextDirectoryURL, withIntermediateDirectories: true)
            try mirrorContent.write(to: contextFileURL, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            // Mirror output is best-effort and should not break pipeline execution.
        }
    }

    // MARK: - Private

    private static func isSupportedExpression(_ expression: String) -> Bool {
        expression.hasPrefix("step:") || expression.hasPrefix("pipeline.")
    }

    private func resolveExpression(
        _ expression: String,
        currentStepID: UUID,
        allowedDependencies: Set<UUID>
    ) throws -> String {
        if expression.hasPrefix("step:") {
            return try resolveStepExpression(
                expression,
                currentStepID: currentStepID,
                allowedDependencies: allowedDependencies
            )
        }

        if expression == "pipeline.failed_steps" {
            let failed = orderedEntries()
                .filter { $0.status == .failed }
                .map(\.stepName)
            return failed.isEmpty ? "(none)" : failed.joined(separator: ", ")
        }

        if expression == "pipeline.last_failed.summary" {
            let latestFailed = orderedEntries()
                .filter { $0.status == .failed }
                .last
            if let latestFailed {
                if !latestFailed.summary.isEmpty {
                    return latestFailed.summary
                }
                if !latestFailed.errorTail.isEmpty {
                    return latestFailed.errorTail
                }
                return "Step \(latestFailed.stepName) failed without textual output."
            }
            return "(none)"
        }

        throw ContextError.unsupportedExpression(expression)
    }

    private func resolveStepExpression(
        _ expression: String,
        currentStepID: UUID,
        allowedDependencies: Set<UUID>
    ) throws -> String {
        let body = String(expression.dropFirst("step:".count))
        guard let dotIndex = body.firstIndex(of: ".") else {
            throw ContextError.invalidReference(expression)
        }

        let rawReference = String(body[..<dotIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let field = String(body[body.index(after: dotIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawReference.isEmpty, !field.isEmpty else {
            throw ContextError.invalidReference(expression)
        }

        let stepID = try resolveStepID(for: rawReference)
        guard stepID != currentStepID else {
            throw ContextError.inaccessibleStepReference(rawReference)
        }
        guard allowedDependencies.contains(stepID) else {
            throw ContextError.inaccessibleStepReference(rawReference)
        }
        guard let entry = entries[stepID] else {
            throw ContextError.unresolvedStepReference(rawReference)
        }
        guard entry.status != .pending, entry.status != .running else {
            throw ContextError.unresolvedField("Step \"\(entry.stepName)\" has not finished yet.")
        }

        if field == "summary" {
            if !entry.summary.isEmpty {
                return entry.summary
            }
            return "Step \(entry.stepName) completed without summary content."
        }

        if field == "decisions" {
            if entry.decisions.isEmpty {
                return "(no recorded decisions)"
            }
            return entry.decisions.map { "- \($0)" }.joined(separator: "\n")
        }

        if field == "artifacts" {
            if entry.artifacts.isEmpty {
                return "(no recorded artifacts)"
            }
            return entry.artifacts.map { "- \($0)" }.joined(separator: "\n")
        }

        if field.hasPrefix("output.tail") {
            let tailLimit = Self.tailLimit(from: field, defaultLimit: budget.maxTailChars)
            return Self.trimmedTail(of: entry.outputTail, maxChars: tailLimit)
        }

        if field.hasPrefix("error.tail") {
            let tailLimit = Self.tailLimit(from: field, defaultLimit: budget.maxTailChars)
            return Self.trimmedTail(of: entry.errorTail, maxChars: tailLimit)
        }

        throw ContextError.unsupportedExpression(expression)
    }

    private func resolveStepID(for reference: String) throws -> UUID {
        if let uuid = UUID(uuidString: reference), entries[uuid] != nil {
            return uuid
        }

        let normalized = Self.normalizedReference(reference)
        guard let matches = stepIDsByNormalizedName[normalized], !matches.isEmpty else {
            throw ContextError.unresolvedStepReference(reference)
        }
        if matches.count > 1 {
            throw ContextError.ambiguousStepReference(reference)
        }
        return matches[0]
    }

    private func orderedEntries() -> [StepContextEntry] {
        stepOrder.compactMap { entries[$0] }
    }

    private func clipInjectedValue(_ raw: String, remainingBudget: inout Int) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "(empty)" }

        var value = cleaned
        if value.count > budget.maxInjectedCharsPerReference {
            value = String(value.prefix(budget.maxInjectedCharsPerReference))
            value += " ...[truncated]"
        }

        guard remainingBudget > 0 else {
            return "[context omitted: budget exceeded]"
        }

        if value.count <= remainingBudget {
            remainingBudget -= value.count
            return value
        }

        let reservedSuffix = " ...[truncated]"
        let prefixBudget = max(0, remainingBudget - reservedSuffix.count)
        let prefix = prefixBudget > 0 ? String(value.prefix(prefixBudget)) : ""
        remainingBudget = 0
        return prefix + reservedSuffix
    }

    private func renderMirrorContent() -> String {
        var lines: [String] = []
        lines.append("# AgentCrew Run Context")
        lines.append("")
        lines.append("Generated at: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("This file mirrors in-memory run context for debugging and human inspection.")
        lines.append("Execution resolves templates from in-memory state, not from this file.")
        lines.append("")

        for entry in orderedEntries() {
            lines.append("## \(entry.stepName)")
            lines.append("")
            lines.append("- Step ID: \(entry.stepID.uuidString)")
            lines.append("- Status: \(entry.status.rawValue)")
            if let exitCode = entry.exitCode {
                lines.append("- Exit code: \(exitCode)")
            }
            if !entry.summary.isEmpty {
                lines.append("- Summary: \(entry.summary)")
            }
            if !entry.decisions.isEmpty {
                lines.append("- Decisions:")
                for decision in entry.decisions {
                    lines.append("  - \(decision)")
                }
            }
            if !entry.artifacts.isEmpty {
                lines.append("- Artifacts:")
                for artifact in entry.artifacts {
                    lines.append("  - \(artifact)")
                }
            }
            if !entry.outputTail.isEmpty {
                lines.append("- Output tail:")
                lines.append("```text")
                lines.append(entry.outputTail)
                lines.append("```")
            }
            if !entry.errorTail.isEmpty {
                lines.append("- Error tail:")
                lines.append("```text")
                lines.append(entry.errorTail)
                lines.append("```")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func clippedMirrorContent(_ content: String) -> String {
        guard content.count > budget.maxMirrorFileChars else { return content }
        let suffix = String(content.suffix(max(0, budget.maxMirrorFileChars - 64)))
        return """
        # AgentCrew Run Context

        ...mirror content truncated...

        \(suffix)
        """
    }

    private static func normalizedReference(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func tailLimit(from field: String, defaultLimit: Int) -> Int {
        guard let colonIndex = field.lastIndex(of: ":") else { return defaultLimit }
        let numberPart = field[field.index(after: colonIndex)...]
        guard let parsed = Int(numberPart), parsed > 0 else { return defaultLimit }
        return min(parsed, 10_000)
    }

    private static func buildDependencyClosure(from steps: [ResolvedStep]) -> [UUID: Set<UUID>] {
        let dependenciesByStep = Dictionary(uniqueKeysWithValues: steps.map { ($0.step.id, $0.allDependencies) })
        var cache: [UUID: Set<UUID>] = [:]

        func dfs(_ stepID: UUID) -> Set<UUID> {
            if let cached = cache[stepID] {
                return cached
            }
            var visited: Set<UUID> = []
            let direct = dependenciesByStep[stepID] ?? []
            for dep in direct {
                visited.insert(dep)
                visited.formUnion(dfs(dep))
            }
            cache[stepID] = visited
            return visited
        }

        for step in steps {
            _ = dfs(step.step.id)
        }
        return cache
    }

    private static func trimmedTail(of text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.suffix(maxChars))
    }

    private static func buildSummary(for result: StepResult, maxChars: Int) -> String {
        let raw = result.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            if result.cancelledByUser {
                return "Step cancelled by user."
            }
            if result.failed {
                return "Step failed with exit code \(result.exitCode)."
            }
            return "Step completed without textual output."
        }

        let compact = compactWhitespace(raw)
        if compact.count <= maxChars {
            return compact
        }
        return String(compact.prefix(maxChars)) + " ...[truncated]"
    }

    private static func extractDecisions(from result: StepResult, maxItems: Int, maxCharsPerItem: Int) -> [String] {
        let text = "\(result.output)\n\(result.error)"
        guard !text.isEmpty else { return [] }

        let keywords = [
            "decision", "decide", "decided", "choose", "chosen", "selected", "using", "use ",
            "决定", "选择", "采用", "方案"
        ]
        var seen: Set<String> = []
        var decisions: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            let lower = trimmedLine.lowercased()
            let hasKeyword = keywords.contains { lower.contains($0) }
            guard hasKeyword else { continue }

            let normalized = compactWhitespace(
                trimmedLine
                    .replacingOccurrences(of: #"^[-*•\d\.\)\s]+"#, with: "", options: .regularExpression)
            )
            guard !normalized.isEmpty else { continue }

            let clipped = normalized.count > maxCharsPerItem
                ? String(normalized.prefix(maxCharsPerItem)) + " ..."
                : normalized
            let dedupeKey = clipped.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            decisions.append(clipped)
            if decisions.count >= maxItems {
                break
            }
        }

        return decisions
    }

    private static func extractArtifacts(from result: StepResult, maxItems: Int, maxCharsPerItem: Int) -> [String] {
        let text = "\(result.output)\n\(result.error)"
        guard !text.isEmpty else { return [] }

        var artifacts: [String] = []
        var seen: Set<String> = []

        let patterns = [
            #"`([^`]+)`"#,
            #"(?:(?:^|\s))([./~]?[A-Za-z0-9_\-./]+(?:\.[A-Za-z0-9_\-]+))"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = text as NSString
            let matches = regex.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: source.length)
            )

            for match in matches {
                guard match.numberOfRanges > 1 else { continue }
                let candidate = source.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard isLikelyPath(candidate) else { continue }

                let clipped = candidate.count > maxCharsPerItem
                    ? String(candidate.prefix(maxCharsPerItem))
                    : candidate
                let key = clipped.lowercased()
                guard seen.insert(key).inserted else { continue }
                artifacts.append(clipped)
                if artifacts.count >= maxItems {
                    return artifacts
                }
            }
        }

        return artifacts
    }

    private static func isLikelyPath(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard !value.contains("://") else { return false }
        guard !value.hasPrefix("--") else { return false }
        guard value.count <= 300 else { return false }
        return value.contains("/") || value.contains(".")
    }

    private static func compactWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enforceRunStoreBudgetIfNeeded() {
        var total = approximateRunStoreSize()
        guard total > budget.maxRunStoreChars else { return }

        // Trim oldest finalized entries first so recent steps keep richer context.
        let sortedEntryIDs = orderedEntries()
            .sorted { lhs, rhs in
                let lhsTime = lhs.finishedAt ?? .distantFuture
                let rhsTime = rhs.finishedAt ?? .distantFuture
                if lhsTime != rhsTime { return lhsTime < rhsTime }
                return lhs.stepName < rhs.stepName
            }
            .map(\.stepID)

        for stepID in sortedEntryIDs {
            guard total > budget.maxRunStoreChars else { break }
            guard var entry = entries[stepID] else { continue }

            let currentOutputTail = entry.outputTail
            let currentErrorTail = entry.errorTail
            if currentOutputTail.isEmpty, currentErrorTail.isEmpty { continue }

            let reducedOutputMax = max(400, currentOutputTail.count / 2)
            let reducedErrorMax = max(400, currentErrorTail.count / 2)
            entry.outputTail = Self.trimmedTail(of: currentOutputTail, maxChars: reducedOutputMax)
            entry.errorTail = Self.trimmedTail(of: currentErrorTail, maxChars: reducedErrorMax)
            entries[stepID] = entry
            total = approximateRunStoreSize()
        }
    }

    private func approximateRunStoreSize() -> Int {
        entries.values.reduce(into: 0) { partial, entry in
            partial += entry.summary.count
            partial += entry.outputTail.count
            partial += entry.errorTail.count
            partial += entry.decisions.reduce(0) { $0 + $1.count }
            partial += entry.artifacts.reduce(0) { $0 + $1.count }
        }
    }
}
