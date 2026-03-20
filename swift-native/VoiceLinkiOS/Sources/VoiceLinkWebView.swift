import AVFoundation
import SwiftUI
import UIKit
import WebKit

final class IOSAudioSessionManager {
    static let shared = IOSAudioSessionManager()

    private var activeRoomSessionCount = 0
    private var observersRegistered = false

    private init() {
        registerObserversIfNeeded()
    }

    func activateForRoomSession() {
        activeRoomSessionCount += 1
        configureAndActivateSession()
    }

    func deactivateRoomSessionIfPossible() {
        activeRoomSessionCount = max(0, activeRoomSessionCount - 1)
        guard activeRoomSessionCount == 0 else { return }
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("[VoiceLinkiOS] Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    private var session: AVAudioSession {
        AVAudioSession.sharedInstance()
    }

    private func registerObserversIfNeeded() {
        guard !observersRegistered else { return }
        observersRegistered = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func configureAndActivateSession() {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            try? session.overrideOutputAudioPort(.speaker)
            NotificationCenter.default.post(name: .iosAudioSessionReactivated, object: nil)
        } catch {
            NSLog("[VoiceLinkiOS] Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard activeRoomSessionCount > 0,
              let userInfo = notification.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }
        if type == .ended {
            configureAndActivateSession()
        }
    }

    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard activeRoomSessionCount > 0,
              let userInfo = notification.userInfo,
              let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return
        }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .categoryChange, .routeConfigurationChange:
            configureAndActivateSession()
        default:
            break
        }
    }

    @objc private func handleMediaServicesReset() {
        guard activeRoomSessionCount > 0 else { return }
        configureAndActivateSession()
    }

    @objc private func handleApplicationDidBecomeActive() {
        guard activeRoomSessionCount > 0 else { return }
        configureAndActivateSession()
    }
}

struct VoiceLinkWebView: UIViewRepresentable {
    let url: URL
    let displayName: String
    let showChat: Bool
    let inputGain: Double
    let outputGain: Double
    let mediaMuted: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.bridgeName)

        let script = WKUserScript(
            source: context.coordinator.bootstrapScript(displayName: displayName, showChat: showChat),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .onDrag
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateIdentity(
            displayName: displayName,
            showChat: showChat,
            inputGain: inputGain,
            outputGain: outputGain,
            mediaMuted: mediaMuted
        )
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.bridgeName)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let bridgeName = "voicelinkNative"

        private weak var webView: WKWebView?
        private var observers: [NSObjectProtocol] = []
        private var lastIdentityScript = ""

        func attach(to webView: WKWebView) {
            self.webView = webView
            observeNotifications()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            webView = nil
        }

        func updateIdentity(displayName: String, showChat: Bool, inputGain: Double, outputGain: Double, mediaMuted: Bool) {
            let escapedName = displayName.jsEscapedLiteral
            let visible = showChat ? "true" : "false"
            let inputValue = String(format: "%.3f", inputGain)
            let outputValue = String(format: "%.3f", outputGain)
            let mediaValue = mediaMuted ? "true" : "false"
            let script = """
            localStorage.setItem('voicelink_auth_display_name', '\(escapedName)');
            localStorage.setItem('voicelink_display_name', '\(escapedName)');
            localStorage.setItem('voicelink_ios_input_gain', '\(inputValue)');
            localStorage.setItem('voicelink_ios_output_gain', '\(outputValue)');
            localStorage.setItem('voicelink_ios_media_muted', '\(mediaValue)');
            if (document.getElementById('user-name') && !document.getElementById('user-name').value) {
                document.getElementById('user-name').value = '\(escapedName)';
            }
            window.__voicelinkSetChatVisible?.(\(visible));
            window.__voicelinkApplyAudioSettings?.({
              inputGain: \(inputValue),
              outputGain: \(outputValue),
              mediaMuted: \(mediaValue)
            });
            """
            lastIdentityScript = script
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        private func reassertAudioBridge() {
            guard let webView else { return }
            let script = lastIdentityScript + "\nwindow.__voicelinkApplyAudioSettings?.({});\nwindow.__voicelinkResumeAudio?.(true);"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.bridgeName,
                  let payload = message.body as? [String: Any],
                  let event = payload["event"] as? String else {
                return
            }

            switch event {
            case "roomUsers":
                let roomId = payload["roomId"] as? String ?? ""
                let users = payload["users"] as? [[String: String]] ?? []
                NotificationCenter.default.post(
                    name: .iosRoomUsersUpdated,
                    object: nil,
                    userInfo: ["roomId": roomId, "users": users]
                )
            case "roomMessage":
                NotificationCenter.default.post(
                    name: .iosRoomMessageEvent,
                    object: nil,
                    userInfo: payload
                )
            case "directMessage":
                NotificationCenter.default.post(
                    name: .iosDirectMessageEvent,
                    object: nil,
                    userInfo: payload
                )
            default:
                break
            }
        }

        func bootstrapScript(displayName: String, showChat: Bool) -> String {
            let escapedName = displayName.jsEscapedLiteral
            let chatVisible = showChat ? "true" : "false"
            return """
            (() => {
              const bridgeName = '\(Self.bridgeName)';
              const safePost = (payload) => {
                try {
                  const handler = window.webkit?.messageHandlers?.[bridgeName];
                  if (handler) handler.postMessage(payload);
                } catch (_) {}
              };
              const displayName = '\(escapedName)';
              try {
                localStorage.setItem('voicelink_auth_display_name', displayName);
                localStorage.setItem('voicelink_display_name', displayName);
              } catch (_) {}

              window.__voicelinkApplyAudioSettings = (settings = {}) => {
                try {
                  const inputGain = Number(settings.inputGain ?? localStorage.getItem('voicelink_ios_input_gain') ?? 1);
                  const outputGain = Number(settings.outputGain ?? localStorage.getItem('voicelink_ios_output_gain') ?? 1);
                  const mediaMuted = String(settings.mediaMuted ?? localStorage.getItem('voicelink_ios_media_muted') ?? 'false') === 'true';

                  const audioEls = Array.from(document.querySelectorAll('audio, video'));
                  for (const el of audioEls) {
                    try {
                      el.muted = mediaMuted;
                      el.volume = Math.max(0, Math.min(1, outputGain / 2));
                    } catch (_) {}
                  }

                  if (window.app) {
                    try { window.app.masterVolume = outputGain; } catch (_) {}
                    try { window.app.inputVolume = inputGain; } catch (_) {}
                  }
                } catch (_) {}
              };

              window.__voicelinkLastAudioResumeAt = 0;
              window.__voicelinkResumeAudio = async (force = false) => {
                try {
                  const now = Date.now();
                  if (!force && now - (window.__voicelinkLastAudioResumeAt || 0) < 3000) return;
                  window.__voicelinkLastAudioResumeAt = now;
                  if (window.iosAudioProfile?.unlockAudio) await window.iosAudioProfile.unlockAudio();
                  if (window.iosCompatibility?.resumeAudio) await window.iosCompatibility.resumeAudio();
                  if (window.iosCompatibility?.unlockAudio) await window.iosCompatibility.unlockAudio();
                  const mediaEls = Array.from(document.querySelectorAll('audio, video'));
                  for (const el of mediaEls) {
                    const isPlayable = !el.muted && el.paused && !el.ended && Number(el.readyState || 0) >= 2;
                    if (!isPlayable) continue;
                    try { await el.play(); } catch (_) {}
                  }
                  if (window.app?.audioContext?.state === 'suspended') {
                    try { await window.app.audioContext.resume(); } catch (_) {}
                  }
                  if (window.app?.peekAudioContext?.state === 'suspended') {
                    try { await window.app.peekAudioContext.resume(); } catch (_) {}
                  }
                  window.__voicelinkApplyAudioSettings?.({});
                } catch (_) {}
              };

              window.__voicelinkSetChatVisible = (visible) => {
                const chatPanel = document.querySelector('.chat-panel');
                const audioPanel = document.querySelector('.audio-panel');
                const userPanel = document.querySelector('.user-panel');
                if (chatPanel) chatPanel.style.display = visible ? '' : 'none';
                if (audioPanel) audioPanel.style.flex = visible ? '1 1 0' : '1.35 1 0';
                if (userPanel) userPanel.style.flex = visible ? '0 0 250px' : '0 0 290px';
              };

              const roomId = () =>
                new URLSearchParams(window.location.search).get('room') ||
                document.getElementById('join-room-id')?.value ||
                document.getElementById('room-id-display')?.textContent?.replace(/^Room ID:\\s*/, '') ||
                '';

              const roomName = () =>
                document.getElementById('current-room-name')?.textContent?.trim() ||
                document.getElementById('join-room-name')?.textContent?.trim() ||
                'Room';

              const collectUsers = () => {
                const userNodes = Array.from(document.querySelectorAll('#user-list .user-item, #user-list .user-entry, #user-list [data-user-id], #user-list > *'));
                const users = userNodes.map((node, index) => {
                  const userId = node.getAttribute?.('data-user-id') || node.dataset?.userId || `user-${index}`;
                  const name = node.getAttribute?.('data-user-name') || node.dataset?.userName || node.textContent?.trim() || 'User';
                  return { id: String(userId), name: String(name) };
                }).filter((entry) => entry.name);
                safePost({ event: 'roomUsers', roomId: roomId(), users });
              };

              const postMessageNode = (node) => {
                if (!(node instanceof HTMLElement)) return;
                const body = node.querySelector('.message-text')?.textContent?.trim() || node.textContent?.trim() || '';
                if (!body) return;
                const author = node.querySelector('.message-author, .message-header strong')?.textContent?.trim()
                  || (node.classList.contains('system-message') ? 'System' : 'User');
                const event = /direct message/i.test(node.textContent || '') ? 'directMessage' : 'roomMessage';
                safePost({
                  event,
                  roomId: roomId(),
                  roomName: roomName(),
                  author,
                  userName: author,
                  body,
                  timestamp: Date.now() / 1000
                });
              };

              const wireObservers = () => {
                const joinName = document.getElementById('user-name');
                if (joinName && !joinName.value && displayName) {
                  joinName.value = displayName;
                }
                window.__voicelinkSetChatVisible(\(chatVisible));

                const userList = document.getElementById('user-list');
                if (userList && !userList.__voicelinkObserved) {
                  userList.__voicelinkObserved = true;
                  collectUsers();
                  new MutationObserver(() => collectUsers()).observe(userList, { childList: true, subtree: true, characterData: true });
                }

                const chatMessages = document.getElementById('chat-messages');
                if (chatMessages && !chatMessages.__voicelinkObserved) {
                  chatMessages.__voicelinkObserved = true;
                  Array.from(chatMessages.children).slice(-20).forEach(postMessageNode);
                  new MutationObserver((records) => {
                    for (const record of records) {
                      record.addedNodes.forEach(postMessageNode);
                    }
                  }).observe(chatMessages, { childList: true, subtree: true });
                }
              };

              const startAudioWatchdog = () => {
                if (window.__voicelinkAudioWatchdogStarted) return;
                window.__voicelinkAudioWatchdogStarted = true;
                setInterval(() => {
                  if (document.hidden) return;
                  const hasSuspendedContext =
                    window.app?.audioContext?.state === 'suspended' ||
                    window.app?.peekAudioContext?.state === 'suspended';
                  const hasPausedAudio = Array.from(document.querySelectorAll('audio, video')).some(
                    (el) => !el.muted && el.paused && !el.ended && Number(el.readyState || 0) >= 2
                  );
                  if (hasSuspendedContext || hasPausedAudio) {
                    window.__voicelinkResumeAudio?.();
                  }
                }, 15000);
              };

              window.addEventListener('load', () => {
                wireObservers();
                window.__voicelinkResumeAudio?.(true);
                startAudioWatchdog();
              }, { once: false });
              document.addEventListener('DOMContentLoaded', () => {
                wireObservers();
                window.__voicelinkResumeAudio?.(true);
                startAudioWatchdog();
              }, { once: false });
              document.addEventListener('visibilitychange', () => {
                if (!document.hidden) {
                  wireObservers();
                  window.__voicelinkResumeAudio?.(true);
                }
              });
              window.addEventListener('pageshow', () => {
                wireObservers();
                window.__voicelinkResumeAudio?.(true);
              });
              ['touchend', 'click'].forEach((eventName) => {
                document.addEventListener(eventName, () => { window.__voicelinkResumeAudio(false); }, { passive: true });
              });
            })();
            """
        }

        private func observeNotifications() {
            guard observers.isEmpty else { return }

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: .iosRequestLeaveRoom,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.webView?.evaluateJavaScript(
                        "document.getElementById('leave-room-btn')?.click();",
                        completionHandler: nil
                    )
                }
            )

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: .iosSetRoomChatVisibility,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    let visible = (notification.userInfo?["visible"] as? Bool) ?? true
                    self?.webView?.evaluateJavaScript(
                        "window.__voicelinkSetChatVisible?.(\(visible ? "true" : "false"));",
                        completionHandler: nil
                    )
                }
            )

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: .iosAudioSessionReactivated,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.reassertAudioBridge()
                }
            )
        }
    }
}

extension Notification.Name {
    static let iosAudioSessionReactivated = Notification.Name("iosAudioSessionReactivated")
}

private extension String {
    var jsEscapedLiteral: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
