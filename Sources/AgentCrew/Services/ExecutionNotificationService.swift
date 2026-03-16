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

    private let center: UNUserNotificationCenter?
    private let presentationDelegate: NotificationPresentationDelegate

    init(center: UNUserNotificationCenter? = nil) {
        if let center {
            self.center = center
        } else if Bundle.main.bundleIdentifier != nil {
            self.center = UNUserNotificationCenter.current()
        } else {
            self.center = nil
        }
        self.presentationDelegate = NotificationPresentationDelegate()
    }

    func authorizationState() async -> ExecutionNotificationAuthorizationState {
        guard center != nil else { return .denied }
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
        guard center != nil else { return false }
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
        guard center != nil else {
            throw ExecutionNotificationServiceError.authorizationDenied
        }

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
        guard let center = self.center else { return }
        let delegate = self.presentationDelegate
        await MainActor.run {
            center.delegate = delegate
        }
    }

    private func currentSettings() async -> UNNotificationSettings {
        guard let center = self.center else {
            fatalError("currentSettings() called without a notification center")
        }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        guard let center = self.center else { return false }
        await configureForegroundPresentation()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async throws {
        guard let center = self.center else {
            throw ExecutionNotificationServiceError.schedulingFailed("No notification center available")
        }
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
            return max(requestedDelay, 3)
        }
        return requestedDelay
    }
}
