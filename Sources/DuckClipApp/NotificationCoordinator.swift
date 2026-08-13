import AppKit
import DuckClipCore
import Foundation
import UserNotifications

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String?) -> Void)?
    var onCopy: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var recentKeys: [String: Date] = [:]

    override init() {
        super.init()
        center.delegate = self
        let copy = UNNotificationAction(identifier: "COPY", title: "Copy response")
        let open = UNNotificationAction(identifier: "OPEN", title: "Open DuckClip", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "AGENT_RESPONSE", actions: [copy, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "AGENT_ALERT", actions: [open], intentIdentifiers: [])
        ])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func post(
        event: AgentEvent,
        itemID: String?,
        enabled: Bool,
        previewMode: NotificationPreviewMode
    ) {
        guard enabled else { return }
        let dedupKey = "\(event.provider.rawValue):\(event.sessionID ?? ""):\(event.kind.rawValue)"
        if let previous = recentKeys[dedupKey], Date().timeIntervalSince(previous) < 2 { return }
        recentKeys[dedupKey] = Date()
        recentKeys = recentKeys.filter { Date().timeIntervalSince($0.value) < 60 }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = body(for: event, mode: previewMode)
        content.sound = .default
        content.categoryIdentifier = itemID == nil ? "AGENT_ALERT" : "AGENT_RESPONSE"
        content.userInfo = ["item_id": itemID ?? ""]
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private func body(for event: AgentEvent, mode: NotificationPreviewMode) -> String {
        switch mode {
        case .firstLine:
            event.message
        case .hidden:
            String(localized: "Open DuckClip to view details.")
        case .metadataOnly:
            switch event.kind {
            case .responseCompleted: String(localized: "A response is ready in DuckClip.")
            case .approvalRequired: String(localized: "The agent needs your approval.")
            case .inputRequired: String(localized: "The agent is waiting for input.")
            case .failed: String(localized: "The agent stopped with an error.")
            case .sessionStarted, .ignored: String(localized: "Open DuckClip to view details.")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let itemID = response.notification.request.content.userInfo["item_id"] as? String
        Task { @MainActor in
            if response.actionIdentifier == "COPY", let itemID, !itemID.isEmpty {
                onCopy?(itemID)
            } else {
                onOpen?(itemID)
            }
            completionHandler()
        }
    }
}
