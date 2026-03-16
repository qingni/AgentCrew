import Foundation
import SwiftUI

@MainActor
final class CLIProfileManager: ObservableObject {
    static let shared = CLIProfileManager()

    @Published var activeProfile: CLIProfile {
        didSet { ProfileStore.save(activeProfile) }
    }
    @Published var hasCompletedSetup: Bool

    @AppStorage("hasCompletedCLISetup") private var storedHasCompletedSetup: Bool = false

    private init() {
        self.hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedCLISetup")
        self.activeProfile = ProfileStore.load()
    }

    var needsFirstRunSetup: Bool {
        !hasCompletedSetup
    }

    // MARK: - Profile Selection

    func selectProfile(_ profile: CLIProfile) {
        activeProfile = profile
    }

    func completeSetup(with profile: CLIProfile) {
        activeProfile = profile
        hasCompletedSetup = true
        storedHasCompletedSetup = true
    }

    func skipSetup() {
        hasCompletedSetup = true
        storedHasCompletedSetup = true
    }

    // MARK: - Auto-detect

    struct DetectionResult: Sendable {
        let executable: String
        let found: Bool
        let path: String?
    }

    func detectEnvironment() async -> (results: [DetectionResult], recommended: CLIProfile) {
        let cli = CLIRunner()
        var results: [DetectionResult] = []
        var foundInternal = false

        for (executable, profileID) in CLIProfile.detectableExecutables {
            let path = await Self.resolveExecutable(executable, cli: cli)
            let found = path != nil
            results.append(DetectionResult(executable: executable, found: found, path: path))
            if found && profileID == "internal" {
                foundInternal = true
            }
        }

        let recommended: CLIProfile = foundInternal ? .internal : .default
        return (results, recommended)
    }

    private nonisolated static func resolveExecutable(_ executable: String, cli: CLIRunner) async -> String? {
        do {
            let result = try await cli.run(
                command: "zsh",
                arguments: ["-lc", "command -v '\(executable)' 2>/dev/null"],
                timeout: 10
            )
            let path = result.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { $0.hasPrefix("/") })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, path.hasPrefix("/") else { return nil }
            return path
        } catch {
            return nil
        }
    }
}

// MARK: - Thread-safe profile access for non-MainActor contexts

enum ProfileStore {
    private static let lock = NSLock()
    private static var cached: CLIProfile = loadFromDisk() ?? .default

    static func current() -> CLIProfile {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    static func save(_ profile: CLIProfile) {
        lock.lock()
        cached = profile
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: fileURL)
    }

    static func load() -> CLIProfile {
        let profile = loadFromDisk() ?? .default
        lock.lock()
        cached = profile
        lock.unlock()
        return profile
    }

    private static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentCrew", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cli-profile.json")
    }

    private static func loadFromDisk() -> CLIProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CLIProfile.self, from: data) else { return nil }
        if let builtIn = CLIProfile.builtInProfile(id: decoded.id) {
            return builtIn
        }
        return decoded
    }
}
