import SwiftUI
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return L10n.text("language.system", fallback: "Follow System")
        case .zhHans:
            return L10n.text("language.zhHans", fallback: "简体中文")
        case .english:
            return L10n.text("language.english", fallback: "English")
        }
    }

    var localeIdentifier: String {
        switch self {
        case .system:
            return Locale.preferredLanguages.first ?? Locale.current.identifier
        case .zhHans:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    var usesChinese: Bool {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
            return preferred.lowercased().hasPrefix("zh")
        case .zhHans:
            return true
        case .english:
            return false
        }
    }
}

private final class LocalizationAdapter {
    static let shared = LocalizationAdapter()

    private let catalog: [String: [String: String]]

    private init(bundle: Bundle = .module) {
        guard
            let url = bundle.url(forResource: "i18n", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else {
            self.catalog = [:]
            return
        }

        self.catalog = decoded
    }

    func localized(for key: String, language: AppLanguage, fallback: String) -> String {
        for candidate in languageCandidates(for: language) {
            if let value = catalog[candidate]?[key], !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    private func languageCandidates(for language: AppLanguage) -> [String] {
        let identifier = language.localeIdentifier
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let prefix = normalized.split(separator: "-").first.map(String.init)

        var candidates: [String] = [normalized]
        if let prefix, prefix != normalized {
            candidates.append(prefix)
        }
        if !candidates.contains("en") {
            candidates.append("en")
        }
        return candidates
    }
}

enum L10n {
    static let storageKey = "appLanguage"

    static func currentLanguage() -> AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static func t(_ zh: String, _ en: String) -> String {
        currentLanguage().usesChinese ? zh : en
    }

    static func text(_ key: String, fallback: String) -> String {
        LocalizationAdapter.shared.localized(
            for: key,
            language: currentLanguage(),
            fallback: fallback
        )
    }
}

extension StepStatus {
    var localizedTitle: String {
        switch self {
        case .pending:
            return L10n.text("status.pending", fallback: "Pending")
        case .running:
            return L10n.text("status.running", fallback: "Running")
        case .completed:
            return L10n.text("status.completed", fallback: "Completed")
        case .failed:
            return L10n.text("status.failed", fallback: "Failed")
        case .skipped:
            return L10n.text("status.skipped", fallback: "Skipped")
        }
    }
}

extension PipelineRunStatus {
    var localizedTitle: String {
        switch self {
        case .running:
            return L10n.text("status.running", fallback: "Running")
        case .completed:
            return L10n.text("status.completed", fallback: "Completed")
        case .failed:
            return L10n.text("status.failed", fallback: "Failed")
        case .cancelled:
            return L10n.text("status.cancelled", fallback: "Cancelled")
        }
    }
}

extension ExecutionMode {
    var localizedTitle: String {
        switch self {
        case .parallel:
            return L10n.text("mode.parallel", fallback: "Parallel")
        case .sequential:
            return L10n.text("mode.sequential", fallback: "Sequential")
        }
    }
}

extension AgentSessionStatus {
    var localizedTitle: String {
        switch self {
        case .created:
            return L10n.text("agent.created", fallback: "Created")
        case .planning:
            return L10n.text("agent.planning", fallback: "Planning")
        case .executing:
            return L10n.text("agent.executing", fallback: "Executing")
        case .evaluating:
            return L10n.text("agent.evaluating", fallback: "Evaluating")
        case .waitingHuman:
            return L10n.text("agent.waitingHuman", fallback: "Waiting Human")
        case .completed:
            return L10n.text("status.completed", fallback: "Completed")
        case .failed:
            return L10n.text("status.failed", fallback: "Failed")
        case .cancelled:
            return L10n.text("status.cancelled", fallback: "Cancelled")
        }
    }
}
