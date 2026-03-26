import Foundation

actor SharedStateStore {
    private typealias JSONDict = [String: Any]

    private struct PersistedSharedState: Codable {
        var rootSessionID: UUID
        var pipelineName: String
        var roundIndex: Int
        var orchestrationMode: OrchestrationMode
        var updatedAt: Date
        var entries: [SharedStateEntry]
        var conflicts: [SharedStateConflict]
    }

    private let budget: SharedStateBudget
    private let workingDirectory: String
    private let pipelineName: String
    private let executionContext: SharedStateExecutionContext
    private let stepOrder: [UUID]
    private let stepNamesByID: [UUID: String]
    private let stageIDsByStepID: [UUID: UUID]
    private let dependencyClosureByStepID: [UUID: Set<UUID>]
    private let rootDirectoryURL: URL?

    private var entries: [UUID: SharedStateEntry]
    private var conflicts: [SharedStateConflict]
    private var isDirty = false

    init(
        steps: [ResolvedStep],
        workingDirectory: String,
        pipelineName: String,
        executionContext: SharedStateExecutionContext,
        budget: SharedStateBudget = .default
    ) {
        self.budget = budget
        self.workingDirectory = workingDirectory
        self.pipelineName = pipelineName
        self.executionContext = executionContext
        self.stepOrder = steps.map { $0.step.id }
        self.stepNamesByID = Dictionary(uniqueKeysWithValues: steps.map { ($0.step.id, $0.step.name) })
        self.stageIDsByStepID = Dictionary(uniqueKeysWithValues: steps.map { ($0.step.id, $0.stageID) })
        self.dependencyClosureByStepID = Self.buildDependencyClosure(from: steps)

        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWorkingDirectory.isEmpty {
            self.rootDirectoryURL = nil
        } else {
            self.rootDirectoryURL = URL(fileURLWithPath: trimmedWorkingDirectory, isDirectory: true)
        }

        if let persisted = Self.loadState(from: Self.sharedStateFileURL(rootDirectoryURL: self.rootDirectoryURL, rootSessionID: executionContext.rootSessionID)) {
            self.entries = Dictionary(uniqueKeysWithValues: persisted.entries.map { ($0.id, $0) })
            self.conflicts = persisted.conflicts
        } else {
            self.entries = [:]
            self.conflicts = []
        }

        Self.prepareDirectoriesIfNeeded(
            rootDirectoryURL: self.rootDirectoryURL,
            rootSessionID: executionContext.rootSessionID,
            roundIndex: executionContext.roundIndex
        )
        let pruned = Self.prunedEntries(self.entries, currentRoundIndex: executionContext.roundIndex)
        self.entries = pruned.entries
        self.isDirty = pruned.dirty
    }

    func freezeSnapshot(for waveIndex: Int) -> SharedStateSnapshot {
        let snapshot = SharedStateSnapshot(
            rootSessionID: executionContext.rootSessionID,
            roundIndex: executionContext.roundIndex,
            waveIndex: waveIndex,
            createdAt: Date(),
            entries: orderedEntries().filter { isEntryVisibleForWave($0, waveIndex: waveIndex) }
        )
        writeWaveSnapshotIfPossible(snapshot)
        return snapshot
    }

    func composePrompt(
        basePrompt: String,
        for step: PipelineStep,
        snapshot: SharedStateSnapshot
    ) -> String {
        let brief = renderBrief(for: step, snapshot: snapshot)
        let contract = renderReportingContract(for: step)

        var sections: [String] = [basePrompt]
        if !brief.isEmpty {
            sections.append(
                """
                Shared state from the same root session:
                \(brief)
                """
            )
        }
        sections.append(contract)

        let rendered = sections.joined(separator: "\n\n")
        writeStepBriefIfPossible(stepID: step.id, content: rendered)
        return rendered
    }

    @discardableResult
    func mergeWaveResults(
        _ results: [StepResult],
        waveIndex: Int
    ) -> SharedStateMergeOutcome {
        var outcome = SharedStateMergeOutcome.empty

        let sortedResults = results.sorted { lhs, rhs in
            let lhsIndex = stepOrder.firstIndex(of: lhs.stepID) ?? .max
            let rhsIndex = stepOrder.firstIndex(of: rhs.stepID) ?? .max
            return lhsIndex < rhsIndex
        }

        for result in sortedResults {
            let stepName = stepNamesByID[result.stepID] ?? result.stepID.uuidString

            if !result.failed && !result.cancelledByUser {
                resolveFailureIssues(for: result.stepID)
            }

            let usedValidOutbox: Bool
            if let delta = loadDelta(for: result.stepID, fallbackStepName: stepName, outcome: &outcome) {
                usedValidOutbox = true
                for proposal in delta.entries {
                    guard let entry = makeEntry(from: proposal, stepID: result.stepID, stepName: stepName, waveIndex: waveIndex, validationErrors: &outcome.validationErrors) else {
                        continue
                    }
                    merge(entry, incomingStepID: result.stepID, outcome: &outcome)
                }
            } else {
                usedValidOutbox = false
            }

            if !usedValidOutbox {
                for proposal in fallbackEntries(for: result, stepName: stepName) {
                    guard let entry = makeEntry(from: proposal, stepID: result.stepID, stepName: stepName, waveIndex: waveIndex, validationErrors: &outcome.validationErrors) else {
                        continue
                    }
                    merge(entry, incomingStepID: result.stepID, outcome: &outcome)
                }
            }
        }

        writeMirrorFilesIfNeeded()
        return outcome
    }

    func writeMirrorFilesIfNeeded(force: Bool = false) {
        guard force || isDirty else { return }
        guard let stateFileURL = Self.sharedStateFileURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: executionContext.rootSessionID),
              let runMirrorFileURL = Self.sharedStateMirrorFileURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: executionContext.rootSessionID),
              let latestMirrorFileURL = Self.latestSharedStateMirrorFileURL(rootDirectoryURL: rootDirectoryURL)
        else { return }

        let persisted = PersistedSharedState(
            rootSessionID: executionContext.rootSessionID,
            pipelineName: pipelineName,
            roundIndex: executionContext.roundIndex,
            orchestrationMode: executionContext.orchestrationMode,
            updatedAt: Date(),
            entries: orderedEntries(),
            conflicts: conflicts
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let json = try encoder.encode(persisted)
            try json.write(to: stateFileURL, options: .atomic)
            try clippedMirrorContent(renderMirrorContent()).write(to: runMirrorFileURL, atomically: true, encoding: .utf8)
            try clippedMirrorContent(renderMirrorContent()).write(to: latestMirrorFileURL, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            // Shared-state persistence is best-effort and should not interrupt pipeline execution.
        }
    }

    // MARK: - Merge

    private func merge(
        _ incoming: SharedStateEntry,
        incomingStepID: UUID,
        outcome: inout SharedStateMergeOutcome
    ) {
        if let duplicate = duplicateEntry(for: incoming) {
            if entries[duplicate.id]?.updatedAt != incoming.updatedAt {
                entries[duplicate.id]?.updatedAt = incoming.updatedAt
                isDirty = true
            }
            return
        }

        if incoming.kind == .decision,
           let incomingDecision = incoming.decision {
            let decisionKey = decisionConflictKey(scope: incoming.scope, category: incomingDecision.category)
            let activeDecisions = orderedEntries().filter {
                $0.kind == .decision &&
                $0.status == .active &&
                decisionConflictKey(for: $0) == decisionKey
            }

            var supersedeTargets = Set(incoming.supersedes)
            for existing in activeDecisions where existing.source.stepID == incoming.source.stepID {
                supersedeTargets.insert(existing.id)
            }

            if !supersedeTargets.isEmpty {
                supersedeEntries(Array(supersedeTargets), outcome: &outcome)
            }

            let remainingActive = orderedEntries().filter {
                $0.kind == .decision &&
                $0.status == .active &&
                decisionConflictKey(for: $0) == decisionKey
            }

            if let conflicting = remainingActive.first(where: {
                guard let existingDecision = $0.decision else { return false }
                return existingDecision.decision != incomingDecision.decision
                    && (existingDecision.strength == .hard || incomingDecision.strength == .hard)
            }) {
                var conflictedIncoming = incoming
                conflictedIncoming.status = .conflicted
                entries[conflictedIncoming.id] = conflictedIncoming

                let conflict = SharedStateConflict(
                    scope: incoming.scope,
                    existingEntryID: conflicting.id,
                    incomingStepID: incomingStepID,
                    message: "Conflicting hard decision detected for scope \"\(incoming.scope)\" and category \"\(normalizedDecisionCategory(incomingDecision.category))\"."
                )
                conflicts.append(conflict)
                outcome.conflicts.append(conflict)
                isDirty = true
                return
            }
        } else {
            let sameScopeEntries = orderedEntries().filter {
                $0.kind == incoming.kind &&
                $0.scope == incoming.scope &&
                $0.status == .active &&
                $0.source.stepID == incoming.source.stepID &&
                ($0.mutability == .supersedable || incoming.mutability == .supersedable)
            }
            if !sameScopeEntries.isEmpty {
                supersedeEntries(sameScopeEntries.map(\.id), outcome: &outcome)
            }
            if !incoming.supersedes.isEmpty {
                supersedeEntries(incoming.supersedes, outcome: &outcome)
            }
        }

        entries[incoming.id] = incoming
        outcome.activatedEntryIDs.append(incoming.id)
        isDirty = true
    }

    private func supersedeEntries(
        _ entryIDs: [UUID],
        outcome: inout SharedStateMergeOutcome
    ) {
        for entryID in entryIDs {
            guard var entry = entries[entryID] else { continue }
            guard entry.status == .active || entry.status == .conflicted else { continue }
            entry.status = .superseded
            entry.updatedAt = Date()
            entries[entryID] = entry
            outcome.supersededEntryIDs.append(entryID)
            isDirty = true
        }
    }

    private func resolveFailureIssues(for stepID: UUID) {
        let failureScope = failureIssueScope(for: stepID)
        for entry in orderedEntries() where entry.kind == .issue && entry.scope == failureScope && entry.status == .active {
            var mutable = entry
            mutable.status = .resolved
            mutable.updatedAt = Date()
            entries[entry.id] = mutable
            isDirty = true
        }
    }

    // MARK: - Prompt Rendering

    private func renderBrief(
        for step: PipelineStep,
        snapshot: SharedStateSnapshot
    ) -> String {
        let allowedDependencies = dependencyClosureByStepID[step.id] ?? []
        let visibleEntries = snapshot.entries
            .filter { isEntryVisible($0, to: step.id, allowedDependencies: allowedDependencies, snapshotWaveIndex: snapshot.waveIndex) }
            .sorted { lhs, rhs in
                let lhsPriority = priority(of: lhs)
                let rhsPriority = priority(of: rhs)
                if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
                return lhs.updatedAt > rhs.updatedAt
            }

        guard !visibleEntries.isEmpty else { return "" }

        var lines: [String] = []
        var remainingChars = budget.maxPromptChars

        for entry in visibleEntries.prefix(budget.maxBriefEntries) {
            let rendered = Self.clippedLine(renderEntryForBrief(entry), maxChars: budget.maxEntryChars)
            guard !rendered.isEmpty else { continue }
            if rendered.count > remainingChars { break }
            lines.append("- \(rendered)")
            remainingChars -= rendered.count
        }

        return lines.joined(separator: "\n")
    }

    private func renderReportingContract(for step: PipelineStep) -> String {
        """
        Shared-state reporting:
        - If this step creates reusable state for later steps or later rounds in the same root session, write JSON to `\(outboxRelativePath(for: step.id))`.
        - Use EXACT top-level schema:
          {"version":1,"stepID":"\(step.id.uuidString)","stepName":"\(step.name)","entries":[...]}
        - Allowed entry `kind`: "decision" | "fact" | "artifactRef" | "issue" | "resource"
        - Allowed `visibility`: "pipeline" | "dependencyChain"
        - Allowed `mutability`: "immutable" | "supersedable" | "appendOnly" | "ephemeral"
        - Allowed `lifetime`: "session" | "round" | "wave" | "untilResolved"
        - Entry schema:
          {"kind":"...","scope":"...","title":"...","visibility":"...","mutability":"...","lifetime":"...","supersedes":["<uuid>"],"payload":{...}}
        - Payload by kind:
          - decision: {"category":"...","strength":"hard|soft","decision":"...","rationale":"...","constraints":["..."],"artifacts":["..."]}
          - fact: {"statement":"...","evidence":["..."],"confidence":0.8}
          - artifactRef: {"path":"...","role":"generated|sourceFile|testFile|config|report|document|tempOutput","summary":"..."}
          - issue: {"severity":"info|warning|error|blocker","summary":"...","details":["..."],"relatedArtifacts":["..."]}
          - resource: {"kind":"localPort|tempDirectory|sessionReference|fileLock|other","value":"...","expiresAt":"2026-03-26T02:30:00Z"}
        - Output strict JSON only (no markdown / comments).
        - Skip the file if there is no reusable shared state to publish.
        """
    }

    private func renderEntryForBrief(_ entry: SharedStateEntry) -> String {
        switch entry.kind {
        case .decision:
            guard let decision = entry.decision else { return "[decision][\(entry.scope)] \(entry.title)" }
            var parts = ["[decision:\(decision.strength.rawValue)][\(entry.scope)] \(decision.decision)"]
            if !decision.rationale.isEmpty {
                parts.append("Why: \(decision.rationale)")
            }
            if !decision.constraints.isEmpty {
                parts.append("Constraints: \(decision.constraints.joined(separator: "; "))")
            }
            return parts.joined(separator: " | ")
        case .fact:
            guard let fact = entry.fact else { return "[fact][\(entry.scope)] \(entry.title)" }
            return "[fact][\(entry.scope)] \(fact.statement)"
        case .artifactRef:
            guard let artifactRef = entry.artifactRef else { return "[artifact][\(entry.scope)] \(entry.title)" }
            let summary = artifactRef.summary.isEmpty ? artifactRef.role.rawValue : artifactRef.summary
            return "[artifact][\(entry.scope)] \(artifactRef.path) | \(summary)"
        case .issue:
            guard let issue = entry.issue else { return "[issue][\(entry.scope)] \(entry.title)" }
            return "[issue:\(issue.severity.rawValue)][\(entry.scope)] \(issue.summary)"
        case .resource:
            guard let resource = entry.resource else { return "[resource][\(entry.scope)] \(entry.title)" }
            return "[resource][\(entry.scope)] \(resource.kind.rawValue)=\(resource.value)"
        }
    }

    // MARK: - Persistence helpers

    private static func loadState(from fileURL: URL?) -> PersistedSharedState? {
        guard let fileURL else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedSharedState.self, from: data)
    }

    private func writeWaveSnapshotIfPossible(_ snapshot: SharedStateSnapshot) {
        guard let snapshotURL = Self.waveSnapshotFileURL(
            rootDirectoryURL: rootDirectoryURL,
            rootSessionID: executionContext.rootSessionID,
            roundIndex: executionContext.roundIndex,
            waveIndex: snapshot.waveIndex
        ) else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            // Snapshot persistence is best-effort for debugging and replay analysis.
        }
    }

    private func writeStepBriefIfPossible(stepID: UUID, content: String) {
        guard let briefURL = Self.stepBriefFileURL(
            rootDirectoryURL: rootDirectoryURL,
            rootSessionID: executionContext.rootSessionID,
            roundIndex: executionContext.roundIndex,
            stepID: stepID
        ) else { return }

        do {
            try content.write(to: briefURL, atomically: true, encoding: .utf8)
        } catch {
            // Prompt brief mirrors are best-effort only.
        }
    }

    private static func prepareDirectoriesIfNeeded(
        rootDirectoryURL: URL?,
        rootSessionID: UUID,
        roundIndex: Int
    ) {
        guard let rootDirectoryURL else { return }

        let urls = [
            rootDirectoryURL.appendingPathComponent(".agentcrew", isDirectory: true),
            rootDirectoryURL.appendingPathComponent(".agentcrew/runs", isDirectory: true),
            Self.runDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID),
            Self.roundsDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID),
            Self.roundDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex),
            Self.waveSnapshotsDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex),
            Self.stepBriefsDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex),
            Self.stepOutboxDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
        ]

        for url in urls {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                // Directory creation is best-effort; runtime execution should continue.
            }
        }
    }

    private static func runDirectoryURL(rootDirectoryURL: URL, rootSessionID: UUID) -> URL {
        rootDirectoryURL
            .appendingPathComponent(".agentcrew", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(rootSessionID.uuidString.lowercased(), isDirectory: true)
    }

    private static func roundsDirectoryURL(rootDirectoryURL: URL, rootSessionID: UUID) -> URL {
        runDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID)
            .appendingPathComponent("rounds", isDirectory: true)
    }

    private static func roundDirectoryURL(rootDirectoryURL: URL, rootSessionID: UUID, roundIndex: Int) -> URL {
        roundsDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID)
            .appendingPathComponent(String(roundIndex), isDirectory: true)
    }

    private static func waveSnapshotsDirectoryURL(rootDirectoryURL: URL, rootSessionID: UUID, roundIndex: Int) -> URL {
        roundDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
            .appendingPathComponent("wave-snapshots", isDirectory: true)
    }

    private static func stepBriefsDirectoryURL(rootDirectoryURL: URL, rootSessionID: UUID, roundIndex: Int) -> URL {
        roundDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
            .appendingPathComponent("step-briefs", isDirectory: true)
    }

    private static func stepOutboxDirectoryURL(rootDirectoryURL: URL, rootSessionID: UUID, roundIndex: Int) -> URL {
        roundDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
            .appendingPathComponent("step-outbox", isDirectory: true)
    }

    private static func sharedStateFileURL(rootDirectoryURL: URL?, rootSessionID: UUID) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return runDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID)
            .appendingPathComponent("shared-state.json", isDirectory: false)
    }

    private static func sharedStateMirrorFileURL(rootDirectoryURL: URL?, rootSessionID: UUID) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return runDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID)
            .appendingPathComponent("shared-state.md", isDirectory: false)
    }

    private static func latestSharedStateMirrorFileURL(rootDirectoryURL: URL?) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return rootDirectoryURL
            .appendingPathComponent(".agentcrew", isDirectory: true)
            .appendingPathComponent("shared-state.md", isDirectory: false)
    }

    private static func waveSnapshotFileURL(rootDirectoryURL: URL?, rootSessionID: UUID, roundIndex: Int, waveIndex: Int) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return waveSnapshotsDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
            .appendingPathComponent("\(waveIndex).json", isDirectory: false)
    }

    private static func stepBriefFileURL(rootDirectoryURL: URL?, rootSessionID: UUID, roundIndex: Int, stepID: UUID) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return stepBriefsDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
            .appendingPathComponent("\(stepID.uuidString.lowercased()).md", isDirectory: false)
    }

    private static func stepOutboxFileURL(rootDirectoryURL: URL?, rootSessionID: UUID, roundIndex: Int, stepID: UUID) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return stepOutboxDirectoryURL(rootDirectoryURL: rootDirectoryURL, rootSessionID: rootSessionID, roundIndex: roundIndex)
            .appendingPathComponent("\(stepID.uuidString.lowercased()).json", isDirectory: false)
    }

    private func outboxRelativePath(for stepID: UUID) -> String {
        ".agentcrew/runs/\(executionContext.rootSessionID.uuidString.lowercased())/rounds/\(executionContext.roundIndex)/step-outbox/\(stepID.uuidString.lowercased()).json"
    }

    // MARK: - Delta / fallback extraction

    private func loadDelta(
        for stepID: UUID,
        fallbackStepName: String,
        outcome: inout SharedStateMergeOutcome
    ) -> StepSharedStateDelta? {
        guard let outboxURL = Self.stepOutboxFileURL(
            rootDirectoryURL: rootDirectoryURL,
            rootSessionID: executionContext.rootSessionID,
            roundIndex: executionContext.roundIndex,
            stepID: stepID
        ) else { return nil }

        guard FileManager.default.fileExists(atPath: outboxURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: outboxURL)
            if let strictDelta = try? JSONDecoder().decode(StepSharedStateDelta.self, from: data),
               validateDelta(strictDelta, expectedStepID: stepID, fallbackStepName: fallbackStepName, outcome: &outcome) {
                return strictDelta
            }

            if let wireDelta = Self.decodeWireDelta(
                from: data,
                expectedStepID: stepID,
                fallbackStepName: fallbackStepName,
                validationErrors: &outcome.validationErrors
            ),
               validateDelta(wireDelta, expectedStepID: stepID, fallbackStepName: fallbackStepName, outcome: &outcome) {
                return wireDelta
            }

            outcome.validationErrors.append(
                "Failed to decode shared-state delta for step \(fallbackStepName). Ensure JSON uses the documented schema."
            )
            return nil
        } catch {
            outcome.validationErrors.append("Failed to decode shared-state delta for step \(fallbackStepName): \(error.localizedDescription)")
            return nil
        }
    }

    private func validateDelta(
        _ delta: StepSharedStateDelta,
        expectedStepID: UUID,
        fallbackStepName: String,
        outcome: inout SharedStateMergeOutcome
    ) -> Bool {
        if delta.version != 1 {
            outcome.validationErrors.append("Shared-state delta for step \(fallbackStepName) uses unsupported version \(delta.version).")
            return false
        }
        if delta.stepID != expectedStepID {
            outcome.validationErrors.append("Shared-state delta for step \(fallbackStepName) contains mismatched stepID.")
            return false
        }
        if let rootSessionID = delta.rootSessionID, rootSessionID != executionContext.rootSessionID {
            outcome.validationErrors.append("Shared-state delta for step \(fallbackStepName) targets a different root session.")
            return false
        }
        if let roundIndex = delta.roundIndex, roundIndex != executionContext.roundIndex {
            outcome.validationErrors.append("Shared-state delta for step \(fallbackStepName) targets a different round.")
            return false
        }
        return true
    }

    private static func decodeWireDelta(
        from data: Data,
        expectedStepID: UUID,
        fallbackStepName: String,
        validationErrors: inout [String]
    ) -> StepSharedStateDelta? {
        guard let rawObject = try? JSONSerialization.jsonObject(with: data),
              let root = rawObject as? JSONDict
        else {
            return nil
        }

        let version = intValue(root["version"]) ?? 1
        guard version == 1 else {
            validationErrors.append("Shared-state delta for step \(fallbackStepName) uses unsupported version \(version).")
            return nil
        }

        guard let stepIDString = stringValue(root["stepID"]),
              let stepID = UUID(uuidString: stepIDString)
        else {
            validationErrors.append("Shared-state delta for step \(fallbackStepName) is missing a valid stepID.")
            return nil
        }

        guard stepID == expectedStepID else {
            validationErrors.append("Shared-state delta for step \(fallbackStepName) contains mismatched stepID.")
            return nil
        }

        let stepName = firstNonEmpty([
            stringValue(root["stepName"]),
            fallbackStepName
        ]) ?? fallbackStepName

        let rootSessionID = stringValue(root["rootSessionID"]).flatMap(UUID.init(uuidString:))
        let roundIndex = intValue(root["roundIndex"])
        let rawEntries = root["entries"] as? [Any] ?? []

        var entryErrors: [String] = []
        let parsedEntries = rawEntries.flatMap { raw -> [ProposedSharedStateEntry] in
            guard let entry = raw as? JSONDict else {
                entryErrors.append("Ignored one shared-state entry because it is not a JSON object.")
                return []
            }
            return parseWireEntry(
                entry,
                stepID: stepID,
                stepName: stepName,
                validationErrors: &entryErrors
            )
        }

        validationErrors.append(contentsOf: entryErrors)

        return StepSharedStateDelta(
            version: version,
            rootSessionID: rootSessionID,
            roundIndex: roundIndex,
            stepID: stepID,
            stepName: stepName,
            entries: parsedEntries
        )
    }

    private static func parseWireEntry(
        _ rawEntry: JSONDict,
        stepID: UUID,
        stepName: String,
        validationErrors: inout [String]
    ) -> [ProposedSharedStateEntry] {
        guard let rawKind = stringValue(rawEntry["kind"]),
              let kind = parseKind(rawKind)
        else {
            validationErrors.append("Ignored one shared-state entry: unknown or missing `kind`.")
            return []
        }

        let scope = firstNonEmpty([stringValue(rawEntry["scope"])]) ?? "step/\(stepID.uuidString.lowercased())/\(kind.rawValue)"
        let title = firstNonEmpty([stringValue(rawEntry["title"])]) ?? "\(kind.rawValue.capitalized) from \(stepName)"
        let visibility = parseVisibility(rawEntry["visibility"])
        let mutability = parseMutability(rawEntry["mutability"], kind: kind)
        let lifetime = parseLifetime(rawEntry["lifetime"], kind: kind)
        let supersedes = parseUUIDArray(rawEntry["supersedes"])

        let payload = dictionary(rawEntry["payload"])
            ?? dictionary(rawEntry[payloadFieldName(for: kind)])
            ?? [:]

        switch kind {
        case .decision:
            let decision = parseDecisionPayload(payload: payload, title: title, mutability: mutability)
            return [
                ProposedSharedStateEntry(
                    kind: .decision,
                    scope: scope,
                    title: title,
                    visibility: visibility,
                    mutability: mutability,
                    lifetime: lifetime,
                    supersedes: supersedes,
                    decision: decision,
                    fact: nil,
                    artifactRef: nil,
                    issue: nil,
                    resource: nil
                )
            ]
        case .fact:
            let fact = parseFactPayload(payload: payload, title: title)
            return [
                ProposedSharedStateEntry(
                    kind: .fact,
                    scope: scope,
                    title: title,
                    visibility: visibility,
                    mutability: mutability,
                    lifetime: lifetime,
                    supersedes: supersedes,
                    decision: nil,
                    fact: fact,
                    artifactRef: nil,
                    issue: nil,
                    resource: nil
                )
            ]
        case .artifactRef:
            let entries = parseArtifactPayloadEntries(
                payload: payload,
                scope: scope,
                title: title,
                visibility: visibility,
                mutability: mutability,
                lifetime: lifetime,
                supersedes: supersedes
            )
            if entries.isEmpty {
                validationErrors.append("Ignored artifactRef entry \"\(title)\": missing payload.path or payload.files[].path.")
            }
            return entries
        case .issue:
            let defaultSeverity: SharedIssueSeverity = normalizeToken(rawKind).contains("summary") ? .info : .warning
            let issue = parseIssuePayload(payload: payload, title: title, defaultSeverity: defaultSeverity)
            return [
                ProposedSharedStateEntry(
                    kind: .issue,
                    scope: scope,
                    title: title,
                    visibility: visibility,
                    mutability: mutability,
                    lifetime: lifetime,
                    supersedes: supersedes,
                    decision: nil,
                    fact: nil,
                    artifactRef: nil,
                    issue: issue,
                    resource: nil
                )
            ]
        case .resource:
            let resource = parseResourcePayload(payload: payload, title: title)
            return [
                ProposedSharedStateEntry(
                    kind: .resource,
                    scope: scope,
                    title: title,
                    visibility: visibility,
                    mutability: mutability,
                    lifetime: lifetime,
                    supersedes: supersedes,
                    decision: nil,
                    fact: nil,
                    artifactRef: nil,
                    issue: nil,
                    resource: resource
                )
            ]
        }
    }

    private static func parseArtifactPayloadEntries(
        payload: JSONDict,
        scope: String,
        title: String,
        visibility: SharedStateVisibility,
        mutability: SharedStateMutability,
        lifetime: SharedStateLifetime,
        supersedes: [UUID]
    ) -> [ProposedSharedStateEntry] {
        var artifacts: [SharedArtifactRefState] = []

        for fileObject in dictionaryArray(payload["files"]) {
            guard let path = firstNonEmpty([
                stringValue(fileObject["path"]),
                stringValue(fileObject["filePath"])
            ]) else { continue }

            let role = parseArtifactRole(fileObject["role"]) ?? parseArtifactRole(payload["role"]) ?? .generated
            let summary = firstNonEmpty([
                stringValue(fileObject["summary"]),
                stringValue(fileObject["description"]),
                stringValue(payload["summary"])
            ]) ?? title
            artifacts.append(SharedArtifactRefState(path: path, role: role, summary: summary))
        }

        if artifacts.isEmpty {
            for fileValue in stringArray(payload["files"]) {
                let role = parseArtifactRole(payload["role"]) ?? .generated
                let summary = firstNonEmpty([stringValue(payload["summary"])]) ?? title
                artifacts.append(SharedArtifactRefState(path: fileValue, role: role, summary: summary))
            }
        }

        if artifacts.isEmpty,
           let path = firstNonEmpty([
               stringValue(payload["path"]),
               stringValue(payload["filePath"]),
               stringValue(payload["artifactPath"])
           ]) {
            let role = parseArtifactRole(payload["role"]) ?? .generated
            let summary = firstNonEmpty([
                stringValue(payload["summary"]),
                stringValue(payload["description"])
            ]) ?? title
            artifacts.append(SharedArtifactRefState(path: path, role: role, summary: summary))
        }

        if artifacts.isEmpty {
            return []
        }

        return artifacts.enumerated().map { index, artifact in
            let entryScope = artifacts.count == 1
                ? scope
                : "\(scope)/\(slug(artifact.path))/\(index)"
            let entryTitle = artifacts.count == 1 ? title : "\(title) · \(artifact.path)"
            return ProposedSharedStateEntry(
                kind: .artifactRef,
                scope: entryScope,
                title: entryTitle,
                visibility: visibility,
                mutability: mutability,
                lifetime: lifetime,
                supersedes: supersedes,
                decision: nil,
                fact: nil,
                artifactRef: artifact,
                issue: nil,
                resource: nil
            )
        }
    }

    private static func parseDecisionPayload(
        payload: JSONDict,
        title: String,
        mutability: SharedStateMutability
    ) -> SharedDecisionState {
        let category = firstNonEmpty([
            stringValue(payload["category"]),
            stringValue(payload["type"])
        ]) ?? "custom"

        let strength = parseDecisionStrength(payload["strength"])
            ?? (mutability == .immutable ? .hard : .soft)

        let decision = firstNonEmpty([
            stringValue(payload["decision"]),
            stringValue(payload["chosenApproach"]),
            stringValue(payload["statement"]),
            stringValue(payload["summary"]),
            title
        ]) ?? title

        let rationale = firstNonEmpty([
            stringValue(payload["rationale"]),
            stringValue(payload["reason"]),
            stringValue(payload["description"])
        ]) ?? ""

        var constraints = stringArray(payload["constraints"])
        if constraints.isEmpty {
            for rejected in dictionaryArray(payload["rejectedApproaches"]) {
                let rejectedName = firstNonEmpty([stringValue(rejected["name"])]) ?? "Unknown"
                let rejectedReason = firstNonEmpty([stringValue(rejected["reason"])]) ?? ""
                let line = rejectedReason.isEmpty
                    ? "Rejected: \(rejectedName)"
                    : "Rejected \(rejectedName): \(rejectedReason)"
                constraints.append(line)
            }
        }

        var artifacts = stringArray(payload["artifacts"])
        if artifacts.isEmpty, let filePath = firstNonEmpty([stringValue(payload["filePath"])]) {
            artifacts = [filePath]
        }

        return SharedDecisionState(
            category: category,
            strength: strength,
            decision: decision,
            rationale: rationale,
            constraints: constraints,
            artifacts: artifacts
        )
    }

    private static func parseFactPayload(
        payload: JSONDict,
        title: String
    ) -> SharedFactState {
        let statement = firstNonEmpty([
            stringValue(payload["statement"]),
            stringValue(payload["fact"]),
            stringValue(payload["description"]),
            stringValue(payload["summary"]),
            stringValue(payload["verdict"]),
            title
        ]) ?? title

        var evidence = stringArray(payload["evidence"])
        if evidence.isEmpty, let file = firstNonEmpty([stringValue(payload["file"]), stringValue(payload["filePath"])]) {
            evidence = [file]
        }

        return SharedFactState(
            statement: statement,
            evidence: evidence,
            confidence: doubleValue(payload["confidence"])
        )
    }

    private static func parseIssuePayload(
        payload: JSONDict,
        title: String,
        defaultSeverity: SharedIssueSeverity
    ) -> SharedIssueState {
        let severity = parseIssueSeverity(payload["severity"]) ?? defaultSeverity
        let summary = firstNonEmpty([
            stringValue(payload["summary"]),
            stringValue(payload["description"]),
            title
        ]) ?? title

        var details = stringArray(payload["details"])
        if details.isEmpty, let description = firstNonEmpty([stringValue(payload["description"])]) {
            details.append(description)
        }
        if let fix = firstNonEmpty([stringValue(payload["fix"])]) {
            details.append("Fix: \(fix)")
        }

        var relatedArtifacts = stringArray(payload["relatedArtifacts"])
        if relatedArtifacts.isEmpty,
           let file = firstNonEmpty([
               stringValue(payload["file"]),
               stringValue(payload["path"]),
               stringValue(payload["filePath"])
           ]) {
            relatedArtifacts.append(file)
        }

        return SharedIssueState(
            severity: severity,
            summary: summary,
            details: details,
            relatedArtifacts: relatedArtifacts
        )
    }

    private static func parseResourcePayload(
        payload: JSONDict,
        title: String
    ) -> SharedResourceState {
        let kind = parseResourceKind(payload["kind"]) ?? .other
        let value = firstNonEmpty([
            stringValue(payload["value"]),
            stringValue(payload["reference"]),
            title
        ]) ?? title

        let expiresAt: Date?
        if let raw = firstNonEmpty([stringValue(payload["expiresAt"])]) {
            expiresAt = ISO8601DateFormatter().date(from: raw)
        } else {
            expiresAt = nil
        }

        return SharedResourceState(
            kind: kind,
            value: value,
            expiresAt: expiresAt
        )
    }

    private static func payloadFieldName(for kind: SharedStateKind) -> String {
        switch kind {
        case .decision:
            return "decision"
        case .fact:
            return "fact"
        case .artifactRef:
            return "artifactRef"
        case .issue:
            return "issue"
        case .resource:
            return "resource"
        }
    }

    private static func parseKind(_ raw: String) -> SharedStateKind? {
        switch normalizeToken(raw) {
        case "decision":
            return .decision
        case "fact", "schema", "plan", "convention":
            return .fact
        case "artifactref", "artifact", "artifacts":
            return .artifactRef
        case "issue", "reviewfinding", "reviewsummary", "finding":
            return .issue
        case "resource":
            return .resource
        default:
            return nil
        }
    }

    private static func parseVisibility(_ raw: Any?) -> SharedStateVisibility {
        if let raw = raw, let object = dictionary(raw) {
            let kindRaw = firstNonEmpty([
                stringValue(object["kind"]),
                stringValue(object["type"])
            ]) ?? "dependencyChain"
            switch normalizeToken(kindRaw) {
            case "pipeline", "allsteps", "shared", "global":
                return .pipeline
            case "stage":
                if let stageIDRaw = firstNonEmpty([stringValue(object["stageID"]), stringValue(object["stageId"])]),
                   let stageID = UUID(uuidString: stageIDRaw) {
                    return .stage(stageID)
                }
                return .dependencyChain
            case "steps":
                let stepIDs = stringArray(object["stepIDs"]).compactMap(UUID.init(uuidString:))
                return stepIDs.isEmpty ? .dependencyChain : .steps(stepIDs)
            default:
                return .dependencyChain
            }
        }

        if let visibilityRaw = stringValue(raw) {
            switch normalizeToken(visibilityRaw) {
            case "pipeline", "allsteps", "shared", "global":
                return .pipeline
            case "dependencychain", "dependencies", "dependency", "deps", "upstream":
                return .dependencyChain
            default:
                return .dependencyChain
            }
        }

        return .dependencyChain
    }

    private static func parseMutability(_ raw: Any?, kind: SharedStateKind) -> SharedStateMutability {
        if let mutabilityRaw = stringValue(raw) {
            switch normalizeToken(mutabilityRaw) {
            case "immutable", "locked", "fixed":
                return .immutable
            case "supersedable", "replaceable", "mutable":
                return .supersedable
            case "appendonly", "append":
                return .appendOnly
            case "ephemeral", "temporary", "temp":
                return .ephemeral
            default:
                break
            }
        }

        switch kind {
        case .decision:
            return .supersedable
        case .issue:
            return .supersedable
        case .resource:
            return .ephemeral
        case .fact, .artifactRef:
            return .appendOnly
        }
    }

    private static func parseLifetime(_ raw: Any?, kind: SharedStateKind) -> SharedStateLifetime {
        if let lifetimeRaw = stringValue(raw) {
            switch normalizeToken(lifetimeRaw) {
            case "session", "run":
                return .session
            case "round":
                return .round
            case "wave", "step":
                return .wave
            case "untilresolved", "open":
                return .untilResolved
            default:
                break
            }
        }

        switch kind {
        case .issue:
            return .untilResolved
        case .resource:
            return .wave
        case .decision, .fact, .artifactRef:
            return .session
        }
    }

    private static func parseDecisionStrength(_ raw: Any?) -> SharedDecisionStrength? {
        guard let value = stringValue(raw) else { return nil }
        switch normalizeToken(value) {
        case "hard", "must", "required", "strict":
            return .hard
        case "soft", "advisory", "optional":
            return .soft
        default:
            return nil
        }
    }

    private static func parseIssueSeverity(_ raw: Any?) -> SharedIssueSeverity? {
        guard let value = stringValue(raw) else { return nil }
        switch normalizeToken(value) {
        case "blocker", "critical":
            return .blocker
        case "error", "high":
            return .error
        case "warning", "medium":
            return .warning
        case "info", "low":
            return .info
        default:
            return nil
        }
    }

    private static func parseArtifactRole(_ raw: Any?) -> SharedArtifactRole? {
        guard let value = stringValue(raw) else { return nil }
        switch normalizeToken(value) {
        case "generated":
            return .generated
        case "sourcefile", "source":
            return .sourceFile
        case "testfile", "test":
            return .testFile
        case "config", "configuration":
            return .config
        case "report":
            return .report
        case "document", "doc":
            return .document
        case "tempoutput", "temp":
            return .tempOutput
        default:
            return nil
        }
    }

    private static func parseResourceKind(_ raw: Any?) -> SharedResourceKind? {
        guard let value = stringValue(raw) else { return nil }
        switch normalizeToken(value) {
        case "localport", "port":
            return .localPort
        case "tempdirectory", "tmpdir", "directory":
            return .tempDirectory
        case "sessionreference", "sessionid", "session":
            return .sessionReference
        case "filelock", "lock":
            return .fileLock
        case "other":
            return .other
        default:
            return nil
        }
    }

    private static func parseUUIDArray(_ raw: Any?) -> [UUID] {
        stringArray(raw).compactMap(UUID.init(uuidString:))
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = raw as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? Double {
            return Int(value)
        }
        if let value = stringValue(raw), let parsed = Int(value) {
            return parsed
        }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? Int {
            return Double(value)
        }
        if let value = stringValue(raw), let parsed = Double(value) {
            return parsed
        }
        return nil
    }

    private static func stringArray(_ raw: Any?) -> [String] {
        if let values = raw as? [String] {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let values = raw as? [Any] {
            return values.compactMap { stringValue($0) }
        }
        if let value = stringValue(raw) {
            return [value]
        }
        return []
    }

    private static func dictionary(_ raw: Any?) -> JSONDict? {
        raw as? JSONDict
    }

    private static func dictionaryArray(_ raw: Any?) -> [JSONDict] {
        if let values = raw as? [JSONDict] {
            return values
        }
        if let values = raw as? [Any] {
            return values.compactMap { $0 as? JSONDict }
        }
        return []
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.first { candidate in
            guard let candidate else { return false }
            return !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    private static func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private func fallbackEntries(
        for result: StepResult,
        stepName: String
    ) -> [ProposedSharedStateEntry] {
        var proposals: [ProposedSharedStateEntry] = []
        let combinedText = "\(result.output)\n\(result.error)"

        let artifactPaths = Self.extractArtifactPaths(from: combinedText, limit: budget.maxFallbackArtifactsPerStep)
        for path in artifactPaths {
            proposals.append(
                ProposedSharedStateEntry(
                    kind: .artifactRef,
                    scope: "step/\(result.stepID.uuidString.lowercased())/artifact/\(Self.slug(path))",
                    title: "Artifact from \(stepName)",
                    visibility: .dependencyChain,
                    mutability: .appendOnly,
                    lifetime: .session,
                    supersedes: [],
                    decision: nil,
                    fact: nil,
                    artifactRef: SharedArtifactRefState(
                        path: path,
                        role: .generated,
                        summary: "Generated or referenced by \(stepName)"
                    ),
                    issue: nil,
                    resource: nil
                )
            )
        }

        let decisionLines = Self.extractTaggedLines(
            from: combinedText,
            prefixes: ["Decision:", "Decision -", "决定:", "决策:"],
            limit: budget.maxFallbackDecisionsPerStep
        )
        for (index, line) in decisionLines.enumerated() {
            proposals.append(
                ProposedSharedStateEntry(
                    kind: .decision,
                    scope: "step/\(result.stepID.uuidString.lowercased())/decision/\(index)",
                    title: "Observed decision from \(stepName)",
                    visibility: .dependencyChain,
                    mutability: .appendOnly,
                    lifetime: .session,
                    supersedes: [],
                    decision: SharedDecisionState(
                        category: "observed",
                        strength: .soft,
                        decision: line,
                        rationale: "",
                        constraints: [],
                        artifacts: artifactPaths
                    ),
                    fact: nil,
                    artifactRef: nil,
                    issue: nil,
                    resource: nil
                )
            )
        }

        let factLines = Self.extractTaggedLines(
            from: combinedText,
            prefixes: ["Fact:", "事实:", "Observation:", "Observed:"],
            limit: budget.maxFallbackFactsPerStep
        )
        for (index, line) in factLines.enumerated() {
            proposals.append(
                ProposedSharedStateEntry(
                    kind: .fact,
                    scope: "step/\(result.stepID.uuidString.lowercased())/fact/\(index)",
                    title: "Observed fact from \(stepName)",
                    visibility: .dependencyChain,
                    mutability: .appendOnly,
                    lifetime: .session,
                    supersedes: [],
                    decision: nil,
                    fact: SharedFactState(
                        statement: line,
                        evidence: artifactPaths,
                        confidence: nil
                    ),
                    artifactRef: nil,
                    issue: nil,
                    resource: nil
                )
            )
        }

        if result.failed && !result.cancelledByUser {
            let issueSummary = Self.issueSummary(from: result.displayOutput)
            if !issueSummary.isEmpty {
                proposals.append(
                    ProposedSharedStateEntry(
                        kind: .issue,
                        scope: failureIssueScope(for: result.stepID),
                        title: "Failure in \(stepName)",
                        visibility: .pipeline,
                        mutability: .supersedable,
                        lifetime: .untilResolved,
                        supersedes: activeIssueEntryIDs(forScope: failureIssueScope(for: result.stepID)),
                        decision: nil,
                        fact: nil,
                        artifactRef: nil,
                        issue: SharedIssueState(
                            severity: .error,
                            summary: issueSummary,
                            details: [Self.issueExcerpt(from: result.displayOutput, maxChars: 600)],
                            relatedArtifacts: artifactPaths
                        ),
                        resource: nil
                    )
                )
            }
        }

        return proposals
    }

    private func makeEntry(
        from proposal: ProposedSharedStateEntry,
        stepID: UUID,
        stepName: String,
        waveIndex: Int,
        validationErrors: inout [String]
    ) -> SharedStateEntry? {
        guard validate(proposal, validationErrors: &validationErrors) else { return nil }

        let now = Date()
        return SharedStateEntry(
            id: UUID(),
            kind: proposal.kind,
            scope: normalizedScope(proposal.scope, kind: proposal.kind, stepID: stepID),
            title: proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(proposal.kind.rawValue.capitalized) from \(stepName)"
                : proposal.title.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .active,
            visibility: sanitizedVisibility(proposal.visibility, stepID: stepID),
            mutability: proposal.mutability,
            lifetime: proposal.lifetime,
            source: SharedStateSource(
                stepID: stepID,
                stepName: stepName,
                stageID: stageIDsByStepID[stepID],
                roundIndex: executionContext.roundIndex,
                waveIndex: waveIndex
            ),
            supersedes: proposal.supersedes,
            createdAt: now,
            updatedAt: now,
            decision: proposal.decision,
            fact: proposal.fact,
            artifactRef: proposal.artifactRef,
            issue: proposal.issue,
            resource: proposal.resource
        )
    }

    private func validate(
        _ proposal: ProposedSharedStateEntry,
        validationErrors: inout [String]
    ) -> Bool {
        let payloadCount = [
            proposal.decision != nil,
            proposal.fact != nil,
            proposal.artifactRef != nil,
            proposal.issue != nil,
            proposal.resource != nil
        ]
        .filter { $0 }
        .count

        guard payloadCount == 1 else {
            validationErrors.append("Shared-state entry for scope \"\(proposal.scope)\" must contain exactly one payload.")
            return false
        }

        switch proposal.kind {
        case .decision where proposal.decision == nil,
             .fact where proposal.fact == nil,
             .artifactRef where proposal.artifactRef == nil,
             .issue where proposal.issue == nil,
             .resource where proposal.resource == nil:
            validationErrors.append("Shared-state entry for scope \"\(proposal.scope)\" is missing its \(proposal.kind.rawValue) payload.")
            return false
        default:
            return true
        }
    }

    // MARK: - State visibility / ordering

    private func orderedEntries() -> [SharedStateEntry] {
        entries.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func isEntryVisibleForWave(_ entry: SharedStateEntry, waveIndex: Int) -> Bool {
        guard entry.status == .active || entry.status == .conflicted || entry.status == .resolved else {
            return false
        }

        if let expiresAt = entry.resource?.expiresAt, expiresAt < Date() {
            return false
        }

        switch entry.lifetime {
        case .session:
            return entry.status == .active || entry.status == .conflicted
        case .round:
            return entry.source.roundIndex == executionContext.roundIndex && (entry.status == .active || entry.status == .conflicted)
        case .wave:
            return entry.source.roundIndex == executionContext.roundIndex
                && entry.source.waveIndex == waveIndex
                && (entry.status == .active || entry.status == .conflicted)
        case .untilResolved:
            return entry.status == .active || entry.status == .conflicted
        }
    }

    private func isEntryVisible(
        _ entry: SharedStateEntry,
        to stepID: UUID,
        allowedDependencies: Set<UUID>,
        snapshotWaveIndex: Int
    ) -> Bool {
        guard isEntryVisibleForWave(entry, waveIndex: snapshotWaveIndex) else { return false }

        switch entry.visibility.kind {
        case .pipeline:
            return true
        case .dependencyChain:
            guard let sourceStepID = entry.source.stepID else { return true }
            return sourceStepID == stepID || allowedDependencies.contains(sourceStepID)
        case .stage:
            return entry.visibility.stageID == stageIDsByStepID[stepID]
        case .steps:
            return entry.visibility.stepIDs.contains(stepID)
        }
    }

    private func priority(of entry: SharedStateEntry) -> Int {
        switch entry.kind {
        case .decision:
            return entry.decision?.strength == .hard ? 100 : 80
        case .issue:
            switch entry.issue?.severity {
            case .blocker: return 95
            case .error: return 90
            case .warning: return 70
            case .info, nil: return 60
            }
        case .artifactRef:
            return 50
        case .fact:
            return 40
        case .resource:
            return 30
        }
    }

    private func duplicateEntry(for incoming: SharedStateEntry) -> SharedStateEntry? {
        orderedEntries().last { existing in
            existing.kind == incoming.kind &&
            existing.scope == incoming.scope &&
            payloadFingerprint(for: existing) == payloadFingerprint(for: incoming) &&
            existing.status == incoming.status
        }
    }

    private func payloadFingerprint(for entry: SharedStateEntry) -> String {
        switch entry.kind {
        case .decision:
            let decision = entry.decision?.decision ?? ""
            let category = normalizedDecisionCategory(entry.decision?.category ?? "")
            return "decision|\(entry.scope.lowercased())|\(category)|\(decision.lowercased())"
        case .fact:
            let statement = entry.fact?.statement ?? ""
            return "fact|\(entry.scope.lowercased())|\(statement.lowercased())"
        case .artifactRef:
            let path = entry.artifactRef?.path ?? ""
            return "artifact|\(entry.scope.lowercased())|\(path.lowercased())"
        case .issue:
            let summary = entry.issue?.summary ?? ""
            return "issue|\(entry.scope.lowercased())|\(summary.lowercased())"
        case .resource:
            let value = entry.resource?.value ?? ""
            return "resource|\(entry.scope.lowercased())|\(value.lowercased())"
        }
    }

    private func decisionConflictKey(for entry: SharedStateEntry) -> String {
        decisionConflictKey(scope: entry.scope, category: entry.decision?.category ?? "")
    }

    private func decisionConflictKey(scope: String, category: String) -> String {
        "\(scope.lowercased())::\(normalizedDecisionCategory(category))"
    }

    private func normalizedDecisionCategory(_ rawCategory: String) -> String {
        let trimmed = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "custom"
        }
        return trimmed.lowercased()
    }

    private func activeIssueEntryIDs(forScope scope: String) -> [UUID] {
        orderedEntries()
            .filter { $0.kind == .issue && $0.scope == scope && $0.status == .active }
            .map(\.id)
    }

    private func failureIssueScope(for stepID: UUID) -> String {
        Self.failureIssueScope(for: stepID)
    }

    private static func failureIssueScope(for stepID: UUID) -> String {
        "step/\(stepID.uuidString.lowercased())/failure"
    }

    // MARK: - Mirror rendering

    private func renderMirrorContent() -> String {
        var lines: [String] = []
        lines.append("# AgentCrew Shared State")
        lines.append("")
        lines.append("- Root session: \(executionContext.rootSessionID.uuidString)")
        lines.append("- Pipeline: \(pipelineName)")
        lines.append("- Mode: \(executionContext.orchestrationMode.rawValue)")
        lines.append("- Round: \(executionContext.roundIndex)")
        lines.append("- Updated at: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        if !conflicts.isEmpty {
            lines.append("## Conflicts")
            lines.append("")
            for conflict in conflicts {
                lines.append("- Scope: \(conflict.scope)")
                lines.append("  - \(conflict.message)")
            }
            lines.append("")
        }

        let visibleEntries = orderedEntries()
        if visibleEntries.isEmpty {
            lines.append("No shared state entries recorded yet.")
            return lines.joined(separator: "\n")
        }

        for entry in visibleEntries {
            lines.append("## \(entry.title)")
            lines.append("")
            lines.append("- Entry ID: \(entry.id.uuidString)")
            lines.append("- Kind: \(entry.kind.rawValue)")
            lines.append("- Scope: \(entry.scope)")
            lines.append("- Status: \(entry.status.rawValue)")
            lines.append("- Visibility: \(entry.visibility.kind.rawValue)")
            lines.append("- Lifetime: \(entry.lifetime.rawValue)")
            if let stepName = entry.source.stepName {
                lines.append("- Source step: \(stepName)")
            }
            lines.append("- Source round: \(entry.source.roundIndex)")
            if let waveIndex = entry.source.waveIndex {
                lines.append("- Source wave: \(waveIndex)")
            }

            switch entry.kind {
            case .decision:
                if let decision = entry.decision {
                    lines.append("- Decision: \(decision.decision)")
                    if !decision.rationale.isEmpty {
                        lines.append("- Rationale: \(decision.rationale)")
                    }
                    if !decision.constraints.isEmpty {
                        lines.append("- Constraints:")
                        decision.constraints.forEach { lines.append("  - \($0)") }
                    }
                }
            case .fact:
                if let fact = entry.fact {
                    lines.append("- Fact: \(fact.statement)")
                    if !fact.evidence.isEmpty {
                        lines.append("- Evidence: \(fact.evidence.joined(separator: ", "))")
                    }
                }
            case .artifactRef:
                if let artifactRef = entry.artifactRef {
                    lines.append("- Artifact: \(artifactRef.path)")
                    lines.append("- Role: \(artifactRef.role.rawValue)")
                    if !artifactRef.summary.isEmpty {
                        lines.append("- Summary: \(artifactRef.summary)")
                    }
                }
            case .issue:
                if let issue = entry.issue {
                    lines.append("- Severity: \(issue.severity.rawValue)")
                    lines.append("- Summary: \(issue.summary)")
                    if !issue.details.isEmpty {
                        lines.append("- Details:")
                        issue.details.forEach { lines.append("  - \($0)") }
                    }
                }
            case .resource:
                if let resource = entry.resource {
                    lines.append("- Resource: \(resource.kind.rawValue)")
                    lines.append("- Value: \(resource.value)")
                    if let expiresAt = resource.expiresAt {
                        lines.append("- Expires at: \(ISO8601DateFormatter().string(from: expiresAt))")
                    }
                }
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func clippedMirrorContent(_ content: String) -> String {
        guard content.count > budget.maxMirrorChars else { return content }
        let tail = String(content.suffix(max(0, budget.maxMirrorChars - 64)))
        return """
        # AgentCrew Shared State

        ...shared state mirror truncated...

        \(tail)
        """
    }

    // MARK: - Normalization helpers

    private func normalizedScope(_ raw: String, kind: SharedStateKind, stepID: UUID) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "step/\(stepID.uuidString.lowercased())/\(kind.rawValue)"
        }
        return trimmed
    }

    private func sanitizedVisibility(_ visibility: SharedStateVisibility, stepID: UUID) -> SharedStateVisibility {
        switch visibility.kind {
        case .pipeline, .dependencyChain:
            return visibility
        case .stage:
            if visibility.stageID == nil, let stageID = stageIDsByStepID[stepID] {
                return .stage(stageID)
            }
            return visibility.stageID == nil ? .dependencyChain : visibility
        case .steps:
            return visibility.stepIDs.isEmpty ? .steps([stepID]) : visibility
        }
    }

    private static func prunedEntries(
        _ entries: [UUID: SharedStateEntry],
        currentRoundIndex: Int
    ) -> (entries: [UUID: SharedStateEntry], dirty: Bool) {
        var mutableEntries = entries
        var dirty = false
        let now = Date()

        for entry in entries.values {
            guard var mutable = mutableEntries[entry.id] else { continue }

            if let expiresAt = mutable.resource?.expiresAt, expiresAt < now, mutable.status == .active {
                mutable.status = .expired
                mutable.updatedAt = now
                mutableEntries[mutable.id] = mutable
                dirty = true
                continue
            }

            switch mutable.lifetime {
            case .round where mutable.source.roundIndex != currentRoundIndex && mutable.status == .active:
                mutable.status = .expired
                mutable.updatedAt = now
                mutableEntries[mutable.id] = mutable
                dirty = true
            case .wave where mutable.status == .active:
                mutable.status = .expired
                mutable.updatedAt = now
                mutableEntries[mutable.id] = mutable
                dirty = true
            default:
                break
            }
        }

        return (mutableEntries, dirty)
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

    private static func extractTaggedLines(
        from text: String,
        prefixes: [String],
        limit: Int
    ) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            guard let prefix = prefixes.first(where: { lowered.hasPrefix($0.lowercased()) }) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let normalized = compactWhitespace(value)
            guard seen.insert(normalized.lowercased()).inserted else { continue }
            lines.append(normalized)
            if lines.count >= limit { break }
        }
        return lines
    }

    private static func extractArtifactPaths(from text: String, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let patterns = [
            #"`([^`]+)`"#,
            #"(?:(?:^|\s))([./~]?[A-Za-z0-9_\-./]+(?:\.[A-Za-z0-9_\-]+))"#
        ]

        var seen: Set<String> = []
        var matches: [String] = []
        let source = text as NSString

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let regexMatches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: source.length))
            for match in regexMatches {
                guard match.numberOfRanges > 1 else { continue }
                let candidate = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isLikelyPath(candidate) else { continue }
                let key = candidate.lowercased()
                guard seen.insert(key).inserted else { continue }
                matches.append(candidate)
                if matches.count >= limit {
                    return matches
                }
            }
        }

        return matches
    }

    private static func isLikelyPath(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard !value.contains("://") else { return false }
        guard !value.hasPrefix("--") else { return false }
        guard value.count <= 300 else { return false }
        return value.contains("/") || value.contains(".")
    }

    private static func issueSummary(from text: String) -> String {
        let trimmed = compactWhitespace(text)
        guard !trimmed.isEmpty else { return "" }
        if let firstSentence = trimmed.split(separator: ".").first, !firstSentence.isEmpty {
            let sentence = String(firstSentence).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                return clippedLine(sentence, maxChars: 220)
            }
        }
        return clippedLine(trimmed, maxChars: 220)
    }

    private static func issueExcerpt(from text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > maxChars else { return trimmed }
        return "...\(trimmed.suffix(maxChars))"
    }

    private static func compactWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clippedLine(_ value: String, maxChars: Int) -> String {
        guard value.count > maxChars else { return value }
        return String(value.prefix(maxChars)) + " ..."
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let replaced = lowered.replacingOccurrences(of: #"[^a-z0-9._/-]+"#, with: "-", options: .regularExpression)
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
