import SwiftUI
import UserNotifications
import RailwayCore

@MainActor @Observable final class FailureInbox: NSObject, UNUserNotificationCenterDelegate {
    var items: [RailwayNotification] = []
    var error: String?
    var enabled = UserDefaults.standard.bool(forKey: "failureNotifications")
    var requestedID: String?
    private var seen = Set<String>()
    private var initialized = false
    private var generation = UUID()
    func enable() async {
        do {
            enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UserDefaults.standard.set(enabled, forKey: "failureNotifications")
            let inspect = UNNotificationAction(identifier: "inspect", title: "Inspect failure")
            let category = UNNotificationCategory(identifier: "railwayFailure", actions: [inspect], intentIdentifiers: [])
            UNUserNotificationCenter.current().setNotificationCategories([category])
        } catch { self.error = error.localizedDescription }
    }
    func refresh(api: RailwayAPI) async {
        let request = generation
        do {
            let result = try await api.notifications()
            try Task.checkCancellation()
            guard request == generation else { return }
            if initialized, enabled {
                for item in result where item.readAt == nil && !seen.contains(item.id) {
                    guard request == generation else { return }
                    let content = UNMutableNotificationContent()
                    content.title = item.title
                    content.body = "Open Railway to inspect the affected resource."
                    content.categoryIdentifier = "railwayFailure"
                    content.userInfo = ["deliveryId": item.id]
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
                }
            }
            guard request == generation else { return }
            seen.formUnion(result.map(\.id)); initialized = true; items = result; error = nil
        } catch { if request == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func reset() { generation = UUID(); items = []; seen = []; initialized = false; requestedID = nil; error = nil }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["deliveryId"] as? String else { return }
        await MainActor.run { self.requestedID = id; NSApp.activate(ignoringOtherApps: true) }
    }
}
struct NotificationsView: View {
    @Bindable var workspace: Workspace
    @Bindable var inbox: FailureInbox
    let inspect: (RailwayNotification) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Notifications").font(.title2.bold())
                Spacer()
                Button(inbox.enabled ? "Notifications enabled" : "Enable desktop alerts") { Task { await inbox.enable() } }.disabled(inbox.enabled)
                Button("Refresh") {
                    let account = workspace.sessionID
                    Task {
                        do {
                            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID else { return }
                            await inbox.refresh(api: api)
                        } catch { if account == workspace.sessionID { inbox.error = error.localizedDescription } }
                    }
                }
            }
            if let error = inbox.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            List(inbox.items) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if item.readAt == nil { Circle().fill(RailwayTheme.accent).frame(width: 7, height: 7) }
                        Text(item.title).font(.headline)
                        Spacer()
                        Text(item.createdAt).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.notificationInstance.severity).font(.caption).foregroundStyle(.orange)
                    DisclosureGroup("Details and diagnosis") { Text(item.notificationInstance.payload.formatted).font(.callout).textSelection(.enabled) }
                    HStack {
                        Button("Inspect resource") { inspect(item) }.disabled(item.notificationInstance.projectId == nil)
                        if item.readAt == nil {
                            Button("Mark read") {
                                let account = workspace.sessionID
                                Task {
                                    do {
                                        guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID else { return }
                                        try await api.markNotificationRead(item.id)
                                        guard account == workspace.sessionID else { return }
                                        await inbox.refresh(api: api)
                                    } catch { if account == workspace.sessionID { inbox.error = error.localizedDescription } }
                                }
                            }
                        }
                    }
                }.padding(.vertical, 10)
            }.scrollContentBackground(.hidden)
            Text("Desktop alerts refresh while Railway is running. Notification bodies omit resource details on the lock screen.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}
