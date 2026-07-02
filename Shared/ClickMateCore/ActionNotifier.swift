import Foundation
@preconcurrency import UserNotifications

enum ActionNotifier {
    static func notify(titleKey: String, bodyKey: String, bodyArguments: [CVarArg] = []) {
        let title = L10n.string(titleKey)
        let body = bodyArguments.isEmpty
            ? L10n.string(bodyKey)
            : String(format: L10n.string(bodyKey), arguments: bodyArguments)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
