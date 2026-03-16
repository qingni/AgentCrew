import Foundation

enum ExecutionNotificationAuthorizationState: String, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct ExecutionNotificationSettings: Codable, Sendable {
    var isEnabled: Bool
    var notifyOnCompleted: Bool
    var notifyOnFailed: Bool
    var notifyOnCancelled: Bool
    var playSound: Bool

    static let `default` = ExecutionNotificationSettings(
        isEnabled: false,
        notifyOnCompleted: true,
        notifyOnFailed: true,
        notifyOnCancelled: true,
        playSound: true
    )

    init(
        isEnabled: Bool = false,
        notifyOnCompleted: Bool = true,
        notifyOnFailed: Bool = true,
        notifyOnCancelled: Bool = true,
        playSound: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.notifyOnCompleted = notifyOnCompleted
        self.notifyOnFailed = notifyOnFailed
        self.notifyOnCancelled = notifyOnCancelled
        self.playSound = playSound
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case notifyOnCompleted
        case notifyOnFailed
        case notifyOnCancelled
        case playSound
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.notifyOnCompleted = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCompleted) ?? true
        self.notifyOnFailed = try container.decodeIfPresent(Bool.self, forKey: .notifyOnFailed) ?? true
        self.notifyOnCancelled = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCancelled) ?? true
        self.playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? true
    }
}
