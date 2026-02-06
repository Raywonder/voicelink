import Foundation
import SwiftUI

// MARK: - Connection Health Monitor
class ConnectionHealthMonitor: ObservableObject {
    static let shared = ConnectionHealthMonitor()

    @Published var overallHealth: Int = 0 // 0-100%
    @Published var healthStatus: HealthStatus = .disconnected
    @Published var detectedNodes: [DetectedNode] = []
    @Published var connectionDetails: ConnectionDetails = ConnectionDetails()

    // Health check intervals
    private var healthCheckTimer: Timer?
    private let checkInterval: TimeInterval = 10

    enum HealthStatus: String {
        case disconnected = "Disconnected"
        case localOnly = "Local Only"
        case partialConnection = "Partial Connection"
        case connected = "Connected"
        case fullySynced = "Fully Synced"

        var color: Color {
            switch self {
            case .disconnected: return .red
            case .localOnly: return .orange
            case .partialConnection: return .yellow
            case .connected: return .green
            case .fullySynced: return .blue
            }
        }

        var icon: String {
            switch self {
            case .disconnected: return "wifi.slash"
            case .localOnly: return "house.fill"
            case .partialConnection: return "wifi.exclamationmark"
            case .connected: return "wifi"
            case .fullySynced: return "checkmark.circle.fill"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .disconnected: return "No connection. Unable to reach any servers."
            case .localOnly: return "Local connection only. Connected to local server but not internet."
            case .partialConnection: return "Partial connection. Some services unavailable."
            case .connected: return "Connected. Online and operational."
            case .fullySynced: return "Fully synced. All services connected and synchronized."
            }
        }
    }

    struct ConnectionDetails {
        var localServerReachable: Bool = false
        var mainServerReachable: Bool = false
        var apiResponsive: Bool = false
        var websocketConnected: Bool = false
        var latencyMs: Int = 0
        var lastChecked: Date = Date()
    }

    struct DetectedNode: Identifiable {
        let id = UUID()
        let name: String
        let url: String
        let type: NodeType
        var isOnline: Bool
        var latencyMs: Int
        var lastSeen: Date

        enum NodeType: String {
            case local = "Local"
            case lan = "LAN"
            case remote = "Remote"
            case main = "Main Server"
        }
    }

    init() {
        startHealthMonitoring()
    }

    deinit {
        healthCheckTimer?.invalidate()
    }

    // MARK: - Health Monitoring

    func startHealthMonitoring() {
        // Initial check
        performHealthCheck()

        // Periodic checks
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
    }

    func performHealthCheck() {
        let group = DispatchGroup()
        var details = ConnectionDetails()
        var nodes: [DetectedNode] = []

        // Check local server
        group.enter()
        checkServer(url: "http://localhost:4004") { reachable, latency in
            details.localServerReachable = reachable
            if reachable {
                nodes.append(DetectedNode(
                    name: "Local Server",
                    url: "localhost:4004",
                    type: .local,
                    isOnline: true,
                    latencyMs: latency,
                    lastSeen: Date()
                ))
            }
            group.leave()
        }

        // Check main server
        group.enter()
        checkServer(url: "https://voicelink.devinecreations.net") { reachable, latency in
            details.mainServerReachable = reachable
            details.latencyMs = latency
            if reachable {
                nodes.append(DetectedNode(
                    name: "Main Server",
                    url: "voicelink.devinecreations.net",
                    type: .main,
                    isOnline: true,
                    latencyMs: latency,
                    lastSeen: Date()
                ))
            }
            group.leave()
        }

        // Check API
        group.enter()
        checkAPI(url: "https://voicelink.devinecreations.net/api/info") { responsive in
            details.apiResponsive = responsive
            group.leave()
        }

        // Check WebSocket status
        details.websocketConnected = ServerManager.shared.isConnected

        group.notify(queue: .main) { [weak self] in
            details.lastChecked = Date()
            self?.connectionDetails = details
            self?.detectedNodes = nodes
            self?.calculateOverallHealth(details: details)
        }
    }

    private func checkServer(url: String, completion: @escaping (Bool, Int) -> Void) {
        guard let requestURL = URL(string: url) else {
            completion(false, 0)
            return
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 5
        request.httpMethod = "HEAD"

        let startTime = Date()

        URLSession.shared.dataTask(with: request) { _, response, error in
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            let reachable = error == nil && (response as? HTTPURLResponse)?.statusCode ?? 0 < 400
            completion(reachable, latency)
        }.resume()
    }

    private func checkAPI(url: String, completion: @escaping (Bool) -> Void) {
        guard let requestURL = URL(string: url) else {
            completion(false)
            return
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, response, error in
            let success = error == nil &&
                (response as? HTTPURLResponse)?.statusCode == 200 &&
                data != nil
            completion(success)
        }.resume()
    }

    private func calculateOverallHealth(details: ConnectionDetails) {
        var health = 0

        // Local server: 10 points
        if details.localServerReachable {
            health += 10
        }

        // Main server reachable: 30 points
        if details.mainServerReachable {
            health += 30
        }

        // API responsive: 20 points
        if details.apiResponsive {
            health += 20
        }

        // WebSocket connected: 30 points
        if details.websocketConnected {
            health += 30
        }

        // Latency bonus: up to 10 points
        if details.latencyMs > 0 && details.latencyMs < 100 {
            health += 10
        } else if details.latencyMs < 300 {
            health += 5
        }

        overallHealth = min(100, health)

        // Determine status
        switch health {
        case 0:
            healthStatus = .disconnected
        case 1...15:
            healthStatus = .localOnly
        case 16...50:
            healthStatus = .partialConnection
        case 51...90:
            healthStatus = .connected
        default:
            healthStatus = .fullySynced
        }
    }

    // MARK: - Manual Refresh

    func refresh() {
        performHealthCheck()
    }
}

// MARK: - Connection Health View
struct ConnectionHealthView: View {
    @ObservedObject var monitor = ConnectionHealthMonitor.shared
    @State private var showHealthInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Overall Health Bar
            HStack {
                Image(systemName: monitor.healthStatus.icon)
                    .foregroundColor(monitor.healthStatus.color)
                    .accessibilityHidden(true)

                Text("Connection: \(monitor.overallHealth)%")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                // Info button for percentage meanings
                Button(action: { showHealthInfo.toggle() }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .help("What does this percentage mean?")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connection health \(monitor.overallHealth) percent. \(healthMeaning)")

            // Health Progress Bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)
                        .cornerRadius(4)

                    Rectangle()
                        .fill(healthGradient)
                        .frame(width: geometry.size.width * CGFloat(monitor.overallHealth) / 100, height: 8)
                        .cornerRadius(4)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            // Status Text with meaning hint
            HStack {
                Text(monitor.healthStatus.rawValue)
                    .font(.caption)
                    .foregroundColor(monitor.healthStatus.color)

                Text("- \(healthMeaning)")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .accessibilityLabel(monitor.healthStatus.accessibilityLabel)

            // Health info popup
            if showHealthInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection Strength Guide:")
                        .font(.caption.bold())
                        .foregroundColor(.white)

                    Group {
                        Text("0-20%: Offline or local only")
                        Text("21-50%: Partial connection")
                        Text("51-70%: Connected, syncing")
                        Text("71-90%: Fully connected")
                        Text("91-100%: Optimal performance")
                    }
                    .font(.caption2)
                    .foregroundColor(.gray)
                }
                .padding(8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
            }

            // Detected Nodes
            if !monitor.detectedNodes.isEmpty {
                Divider()

                Text("Detected Nodes")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .accessibilityAddTraits(.isHeader)

                ForEach(monitor.detectedNodes) { node in
                    NodeRowView(node: node)
                }
            }

            // Connection Details
            if monitor.connectionDetails.latencyMs > 0 {
                Text("Latency: \(monitor.connectionDetails.latencyMs)ms")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .accessibilityLabel("Network latency is \(monitor.connectionDetails.latencyMs) milliseconds")
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }

    /// Human-readable meaning of current health percentage
    var healthMeaning: String {
        switch monitor.overallHealth {
        case 0:
            return "Completely offline"
        case 1...10:
            return "Local server only"
        case 11...30:
            return "Checking internet"
        case 31...50:
            return "Partial connection"
        case 51...70:
            return "Connected, syncing"
        case 71...90:
            return "Fully connected"
        default:
            return "Optimal"
        }
    }

    var healthGradient: LinearGradient {
        let color: Color = {
            switch monitor.overallHealth {
            case 0...20: return .red
            case 21...50: return .orange
            case 51...80: return .yellow
            default: return .green
            }
        }()

        return LinearGradient(
            gradient: Gradient(colors: [color.opacity(0.7), color]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Node Row View
struct NodeRowView: View {
    let node: ConnectionHealthMonitor.DetectedNode

    var body: some View {
        HStack {
            Circle()
                .fill(node.isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.caption)
                    .foregroundColor(.white)

                Text(node.url)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(node.type.rawValue)
                    .font(.caption2)
                    .foregroundColor(.blue)

                if node.isOnline {
                    Text("\(node.latencyMs)ms")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.name), \(node.type.rawValue), \(node.isOnline ? "online" : "offline")\(node.isOnline ? ", latency \(node.latencyMs) milliseconds" : "")")
    }
}

// MARK: - Health Percentage Meanings
/*
 Connection Health Percentages:

 0%   - No connection at all. Completely offline.
 5%   - Local server detected but not connected.
 10%  - Local server connected only. No internet.
 20%  - Local network available, trying to reach internet.
 30%  - Main server reachable but not connected.
 40%  - Partial connection, some services unavailable.
 50%  - Connected to main server, API not responsive.
 60%  - Connected with API access, WebSocket pending.
 70%  - WebSocket connected, syncing data.
 80%  - Fully connected, minor latency issues.
 90%  - Connected with good latency.
 100% - Fully synced with all APIs, optimal performance.
 */
