import SwiftUI

// MARK: - Self Tests Section
struct AdminSelfTestsSection: View {
    @ObservedObject private var scheduler = SelfTestScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Self Tests verify the local app and server integration paths that VoiceLink depends on.",
                steps: [
                    "Run the tests after changing server config, media setup, or file transfer settings.",
                    "Enable scheduled checks for ongoing installs that should alert when a dependency breaks.",
                    "Review the recent run history to see which checks passed, warned, or failed."
                ],
                docs: [
                    AdminDocLink(title: "Testing Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/getting-started.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Installation Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/index.html")
                ]
            )

            Text("Built-in Self-Test Scheduler")
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 10) {
                ConfigToggle(label: "Enable scheduler", isOn: Binding(
                    get: { scheduler.schedulerEnabled },
                    set: { scheduler.setSchedulerEnabled($0) }
                ))

                ConfigToggle(label: "Run once on app launch", isOn: Binding(
                    get: { scheduler.runOnLaunch },
                    set: { scheduler.setRunOnLaunch($0) }
                ))

                HStack {
                    Text("Interval (minutes)")
                        .foregroundColor(.gray)
                    Spacer()
                    Stepper(value: Binding(
                        get: { scheduler.intervalMinutes },
                        set: { scheduler.setIntervalMinutes($0) }
                    ), in: 1...1440) {
                        Text("\(scheduler.intervalMinutes)")
                            .foregroundColor(.white)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await scheduler.runNow(source: "admin-manual") }
                    } label: {
                        if scheduler.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Running...")
                            }
                        } else {
                            Label("Run Self Tests Now", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scheduler.isRunning)

                    Button("Clear History") {
                        scheduler.clearHistory()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scheduler Status")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                statusRow("Last Run", value: scheduler.lastRunAt.map(Self.dateString) ?? "Never")
                statusRow("Next Run", value: scheduler.nextRunAt.map(Self.dateString) ?? "Not scheduled")
                statusRow("Latest Summary", value: scheduler.lastRunSummary)
                if let error = scheduler.lastError, !error.isEmpty {
                    statusRow("Last Error", value: error)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Enabled Checks")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)

                ForEach(scheduler.checks) { check in
                    HStack {
                        Toggle(check.id.title, isOn: Binding(
                            get: { check.enabled },
                            set: { scheduler.setCheckEnabled(check.id, enabled: $0) }
                        ))
                        .foregroundColor(.white)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Runs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)

                if scheduler.runHistory.isEmpty {
                    Text("No self-test runs yet.")
                        .foregroundColor(.gray)
                        .padding(.vertical, 6)
                } else {
                    ForEach(scheduler.runHistory.prefix(8)) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(Self.dateString(run.finishedAt))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(run.source)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }

                            Text(run.summary)
                                .foregroundColor(.white)
                                .font(.subheadline)

                            ForEach(run.results.prefix(6)) { result in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(color(for: result.status))
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.check.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.white)
                                        Text(result.message)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.78))
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(10)
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
    }

    private func color(for status: SelfTestScheduler.ResultStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
