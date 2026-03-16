import Foundation
import UserNotifications
import AppKit

private final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions
        if #available(macOS 11.0, *) {
            options = [.banner, .list]
        } else {
            options = [.alert]
        }
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}

enum ExecutionNotificationServiceError: LocalizedError {
    case authorizationDenied
    case schedulingFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Notifications are not authorized for AgentCrew."
        case .schedulingFailed(let message):
            return "Failed to schedule notification: \(message)"
        }
    }
}

actor ExecutionNotificationService {
    static let shared = ExecutionNotificationService()

    private let center: UNUserNotificationCenter
    private let presentationDelegate: NotificationPresentationDelegate

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        self.presentationDelegate = NotificationPresentationDelegate()
    }

    func authorizationState() async -> ExecutionNotificationAuthorizationState {
        let settings = await currentSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let status = await authorizationState()
        switch status {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await requestAuthorization()
        }
    }

    func sendLocalNotification(
        identifier: String,
        title: String,
        body: String,
        playSound: Bool,
        delaySeconds: TimeInterval = 0
    ) async throws {
        await configureForegroundPresentation()

        let status = await authorizationState()
        guard status == .authorized else {
            throw ExecutionNotificationServiceError.authorizationDenied
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playSound {
            content.sound = .default
        }
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .active
        }

        let normalizedDelay = await normalizedDeliveryDelay(from: delaySeconds)
        let trigger: UNNotificationTrigger? = normalizedDelay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: normalizedDelay, repeats: false)
            : nil

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await add(request)
        } catch {
            throw ExecutionNotificationServiceError.schedulingFailed(error.localizedDescription)
        }
    }

    func configureForegroundPresentation() async {
        await MainActor.run {
            center.delegate = presentationDelegate
        }
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await configureForegroundPresentation()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func normalizedDeliveryDelay(from delaySeconds: TimeInterval) async -> TimeInterval {
        let requestedDelay = max(0, delaySeconds)
        let appIsActive = await MainActor.run { NSApplication.shared.isActive }
        if appIsActive {
            // If the app is frontmost, give users a short window to switch apps
            // so the banner can still surface in Notification Center UI.
            return max(requestedDelay, 3)
        }
        return requestedDelay
    }
}
