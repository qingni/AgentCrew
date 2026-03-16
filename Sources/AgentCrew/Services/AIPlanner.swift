import Foundation

// MARK: - PlannerError

enum PlannerError: Error, LocalizedError {
    case cliUnavailable
    case commandFailed(String)
    case cancelled
    case emptyResponse
    case invalidResponse
    case parsingError(String)

    var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            "Agent CLI is not available. Make sure `cursor-agent` is installed and logged in."
        case .commandFailed(let msg):
            "Agent CLI failed: \(msg)"
        case .cancelled:
            "Pipeline generation was cancelled."
        case .emptyResponse:
            "Agent CLI returned empty output."
        case .invalidResponse:
            "Failed to find valid pipeline JSON in Agent CLI output."
        case .parsingError(let msg): "Failed to parse pipeline: \(msg)"
        }
    }
}

// MARK: - AIPlanner

/// Calls a configured CLI to decompose a natural-language task
/// description into a structured `Pipeline`.
final class AIPlanner: @unchecked Sendable {
    private let cli = CLIRunner()

    func generatePipeline(
        request: PlanRequest,
        config: LLMConfig,
        onPhaseUpdate: (@Sendable (PlanningPhase) -> Void)? = nil,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> Pipeline {
        onPhaseUpdate?(.preparingContext)
        let prompt = Self.buildPlannerPrompt(
            userPrompt: request.userPrompt,
            tools: request.availableTools,
            customPolicy: config.customPolicy
        )
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LLMConfig.defaultAgent.model
            : config.model.trimmingCharacters(in: .whitespacesAndNewlines)

        let profile = ProfileStore.current()
        let plannerConfig = profile.planner
        let args = plannerConfig.buildArguments(
            prompt: prompt,
            model: model,
            workingDirectory: request.workingDirectory
        )

        let result: CLIResult
        do {
            onPhaseUpdate?(.invokingAgentCLI)
            onPhaseUpdate?(.generatingStructure)
            result = try await cli.run(
                command: plannerConfig.executable,
                arguments: args,
                workingDirectory: request.workingDirectory,
                stdinData: plannerConfig.promptMode == .stdin ? prompt.data(using: .utf8) : nil,
                timeout: 600,
                onOutputChunk: { chunk in
                    guard let onLog else { return }
                    let cleanedChunk = Self.cleanedLogChunk(chunk)
                    if !cleanedChunk.isEmpty {
                        onLog(cleanedChunk)
                    }
                }
            )
        } catch is CancellationError {
            throw PlannerError.cancelled
        } catch CLIError.cancelled {
            throw PlannerError.cancelled
        } catch CLIError.processError(let message) {
            let lower = message.lowercased()
            if lower.contains("not found") || lower.contains("no such file") {
                throw PlannerError.cliUnavailable
            }
            throw PlannerError.commandFailed(message)
        } catch {
            throw PlannerError.commandFailed(error.localizedDescription)
        }

        guard result.exitCode == 0 else {
            let stderr = Self.cleanedOutput(result.stderr)
            let stdout = Self.cleanedOutput(result.stdout)
            let details = !stderr.isEmpty
                ? stderr
                : (!stdout.isEmpty ? stdout : "Exit code \(result.exitCode)")
            throw PlannerError.commandFailed(details)
        }

        let stdout = Self.cleanedOutput(result.stdout)
        let stderr = Self.cleanedOutput(result.stderr)
        let mergedOutput = [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !mergedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerError.emptyResponse
        }

        onPhaseUpdate?(.parsingResult)
        guard let jsonText = Self.extractJSONText(from: stdout)
            ?? Self.extractJSONText(from: mergedOutput)
        else {
            throw PlannerError.invalidResponse
        }

        do {
            let contentData = Data(jsonText.utf8)
            let plan = try JSONDecoder().decode(PlanResponse.self, from: contentData)
            return plan.toPipeline(workingDirectory: request.workingDirectory)
        } catch {
            throw PlannerError.parsingError(error.localizedDescription)
        }
    }

    // MARK: - Prompt

    static func builtInPromptPreview(tools: [ToolType] = ToolType.allCases) -> String {
        buildPlannerPrompt(
            userPrompt: "{{task_description}}",
            tools: tools,
            customPolicy: ""
        )
    }

    private static func buildPlannerPrompt(
        userPrompt: String,
        tools: [ToolType],
        customPolicy: String
    ) -> String {
        let toolList = tools.map(\.rawValue).joined(separator: ", ")
        let trimmedPolicy = customPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
        let policySection = trimmedPolicy.isEmpty
            ? ""
            : """

            Additional planning policy (user-defined):
            \(trimmedPolicy)
            """

        return """
        You are an AI pipeline planner.
        Given a user's task description, generate a structured pipeline as JSON.

        Available tools: \(toolList)

        Tool guidance:
        - codex: Default for implementation, feature work, and verify/fix steps.
        - cursor: Default for code review steps.
        - claude: Optional alternative for analysis/review, but not the default.

        Typical pattern: codex for initial coding, cursor for code review, and codex for verify/fix.

        Planning quality requirements:
        - Ground all major decisions in the repository context; avoid generic assumptions.
        - For non-trivial tasks, include an early analysis/design step that compares 2-3 candidate approaches aligned with mainstream best practices for the detected stack, then proceed with the recommended path.
        - Decompose adaptively by complexity: simple tasks should stay concise (often 1-3 steps), and complex tasks should split only when dependencies, risk, or validation needs justify it.
        - Each step prompt should ask for concrete file-level actions and verification.
        \(policySection)

        Respond with ONLY a valid JSON object (no markdown fences, no prose) in this format:
        {
          "pipelineName": "descriptive name",
          "stages": [
            {
              "name": "stage name",
              "executionMode": "parallel" | "sequential",
              "steps": [
                {
                  "name": "step name",
                  "prompt": "detailed prompt for the AI tool",
                  "recommendedTool": "codex" | "claude" | "cursor",
                  "model": null,
                  "dependsOn": ["other step name"] or null,
                  "continueOnFailure": false
                }
              ]
            }
          ]
        }

        Guidelines:
        1. Break complex tasks into logical stages and steps.
        2. Use parallel mode when steps are independent.
        3. Use sequential mode when order matters within a stage.
        4. Default to codex for coding and verify/fix, and cursor for code review.
        5. Keep plan size proportional to complexity; avoid over-decomposition.
        6. Write clear, detailed prompts for each step.

        User task:
        \(userPrompt)
        """
    }

    private static func cleanedLogChunk(_ text: String) -> String {
        stripANSIEscapeCodes(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func cleanedOutput(_ text: String) -> String {
        stripANSIEscapeCodes(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSIEscapeCodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func extractJSONText(from text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        var candidates: [String] = [cleaned]
        candidates.append(contentsOf: fencedCodeBlockCandidates(in: cleaned))
        candidates.append(contentsOf: jsonObjectCandidates(in: cleaned))

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isValidPlanJSON(trimmed) {
                return trimmed
            }
        }
        return nil
    }

    private static func fencedCodeBlockCandidates(in text: String) -> [String] {
        let pattern = "```(?:json)?\\s*([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
    }

    private static func jsonObjectCandidates(in text: String) -> [String] {
        let chars = Array(text)
        var candidates: [String] = []
        var depth = 0
        var objectStartIndex: Int?
        var inString = false
        var isEscaping = false

        for index in chars.indices {
            let char = chars[index]

            if inString {
                if isEscaping {
                    isEscaping = false
                } else if char == "\\" {
                    isEscaping = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
                continue
            }

            if char == "{" {
                if depth == 0 {
                    objectStartIndex = index
                }
                depth += 1
                continue
            }

            if char == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start = objectStartIndex {
                    candidates.append(String(chars[start...index]))
                    objectStartIndex = nil
                }
            }
        }

        return candidates
    }

    private static func isValidPlanJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(PlanResponse.self, from: data)) != nil
    }
}
