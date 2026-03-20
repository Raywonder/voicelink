import Foundation
import SwiftUI
import UIKit
import UserNotifications

final class IOSPushNotificationManager: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = IOSPushNotificationManager()

    private let defaults = UserDefaults.standard
    private let deviceIdKey = "voicelink.iosPushDeviceId"
    private let tokenKey = "voicelink.iosPushAPNsToken"
    private let tokenRegistrationHashKey = "voicelink.iosPushTokenRegistrationHash"
    private let registrationEnabledKey = "systemActionNotifications"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            await syncRegistrationIfNeeded()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: tokenKey)
        Task { @MainActor in
            await registerCurrentDeviceIfPossible()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[VoiceLinkiOS] APNs registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        handleRemoteNotificationPayload(userInfo, userInitiated: false)
        completionHandler(.newData)
    }

    @MainActor
    func syncRegistrationIfNeeded() async {
        guard isPushEnabled else {
            await unregisterCurrentDeviceIfPossible()
            UIApplication.shared.unregisterForRemoteNotifications()
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
            await registerCurrentDeviceIfPossible()
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            let refreshed = await center.notificationSettings()
            if [.authorized, .provisional, .ephemeral].contains(refreshed.authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
        default:
            break
        }
    }

    @MainActor
    func unregisterCurrentDeviceIfPossible() async {
        guard let request = makePushRequest(path: "/api/push/ios/unregister") else { return }
        do {
            var request = request
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "deviceId": stableDeviceId
            ])
            _ = try await URLSession.shared.data(for: request)
        } catch {
            NSLog("[VoiceLinkiOS] Failed to unregister iOS push device: \(error.localizedDescription)")
        }
        defaults.removeObject(forKey: tokenRegistrationHashKey)
    }

    private var isPushEnabled: Bool {
        defaults.object(forKey: registrationEnabledKey) as? Bool ?? true
    }

    private var stableDeviceId: String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: deviceIdKey)
        return created
    }

    private var currentAuthToken: String {
        (defaults.string(forKey: "voicelink.authToken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentServerBaseURL: String {
        normalizePushBaseURL(defaults.string(forKey: "voicelink.serverURL") ?? "https://voicelink.devinecreations.net")
    }

    @MainActor
    private func registerCurrentDeviceIfPossible() async {
        let authToken = currentAuthToken
        let apnsToken = (defaults.string(forKey: tokenKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authToken.isEmpty, !apnsToken.isEmpty else { return }

        let registrationHash = "\(currentServerBaseURL)|\(stableDeviceId)|\(apnsToken)|\(authToken)"
        if defaults.string(forKey: tokenRegistrationHashKey) == registrationHash {
            return
        }

        guard let requestBase = makePushRequest(path: "/api/push/ios/register") else { return }
        do {
            var request = requestBase
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "deviceId": stableDeviceId,
                "token": apnsToken,
                "bundleId": Bundle.main.bundleIdentifier ?? "net.devinecreations.voicelink.ios",
                "deviceName": UIDevice.current.name,
                "platform": "ios",
                "systemName": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
                "buildNumber": Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
            ])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            defaults.set(registrationHash, forKey: tokenRegistrationHashKey)
        } catch {
            NSLog("[VoiceLinkiOS] Failed to register iOS push token: \(error.localizedDescription)")
        }
    }

    private func makePushRequest(path: String) -> URLRequest? {
        let authToken = currentAuthToken
        guard !authToken.isEmpty, let url = URL(string: "\(currentServerBaseURL)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(authToken, forHTTPHeaderField: "x-session-token")
        return request
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handleRemoteNotificationPayload(notification.request.content.userInfo, userInitiated: false)
        completionHandler([.banner, .badge, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleRemoteNotificationPayload(response.notification.request.content.userInfo, userInitiated: true)
        completionHandler()
    }

    private func handleRemoteNotificationPayload(_ userInfo: [AnyHashable: Any], userInitiated: Bool) {
        let roomId = (userInfo["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = (userInfo["roomName"] as? String ?? userInfo["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let userId = (userInfo["userId"] as? String ?? userInfo["targetUserId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = (userInfo["userName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let openAction = (userInfo["openAction"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !userId.isEmpty || !roomId.isEmpty || openAction == "messages" {
            NotificationCenter.default.post(
                name: .iosOpenMessagesTab,
                object: nil,
                userInfo: [
                    "roomId": roomId,
                    "roomName": roomName,
                    "userId": userId,
                    "userName": userName,
                    "userInitiated": userInitiated
                ]
            )
        }

        if !userName.isEmpty && openAction == "profile" {
            NotificationCenter.default.post(
                name: .iosShowUserProfile,
                object: nil,
                userInfo: [
                    "userName": userName,
                    "userInitiated": userInitiated
                ]
            )
        }
    }
}

private func normalizePushBaseURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://voicelink.devinecreations.net"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    return "https://\(trimmed)"
}
