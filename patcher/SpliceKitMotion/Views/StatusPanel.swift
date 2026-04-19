import SwiftUI

struct StatusPanel: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: headerIcon)
                    .font(.title)
                    .foregroundStyle(headerColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.title.bold())
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Status details
            VStack(alignment: .leading, spacing: 10) {
                if !model.motionVersion.isEmpty {
                    Label {
                        if model.status == .motionUpdateAvailable {
                            Text("Modded copy v\(model.motionVersion) \u{2192} Stock v\(model.stockMotionVersion)")
                        } else {
                            Text("Motion v\(model.motionVersion)")
                        }
                    } icon: {
                        Image(systemName: "sparkles.rectangle.stack")
                    }
                    .font(.subheadline)
                }

                Label {
                    HStack(spacing: 6) {
                        Text(model.bridgeConnected ? "Connected" : "Not Running")
                        Circle()
                            .fill(model.bridgeConnected ? .green : .orange)
                            .frame(width: 8, height: 8)
                    }
                } icon: {
                    Image(systemName: "network")
                }
                .font(.subheadline)
            }

            // Error display
            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1))
                    .cornerRadius(6)
            }

            // Crash-log share status
            if let msg = model.crashShareMessage {
                let accent: Color = model.isSharingCrashLog ? .secondary : .green
                Label(msg, systemImage: model.isSharingCrashLog ? "arrow.up.circle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(accent)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.1))
                    .cornerRadius(6)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    model.uninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }

                Button {
                    model.shareLatestCrashLog()
                } label: {
                    if model.isSharingCrashLog {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Sharing...")
                        }
                    } else {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(model.isSharingCrashLog)
                .help("Upload the latest Motion crash log and MotionKit logs to filebin.net and copy the link to your clipboard.")

                Spacer()

                Button {
                    model.checkStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if model.status == .updateAvailable {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch Motion", systemImage: "play.fill")
                    }

                    Button {
                        model.updateMotionKit()
                    } label: {
                        Label("Update", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if model.status == .motionUpdateAvailable {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch Motion", systemImage: "play.fill")
                    }

                    Button {
                        model.rebuildModdedApp()
                    } label: {
                        Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch Motion", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .task {
            while !Task.isCancelled {
                await model.pollBridgeStatus()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var headerIcon: String {
        switch model.status {
        case .updateAvailable: return "arrow.up.circle.fill"
        case .motionUpdateAvailable: return "exclamationmark.triangle.fill"
        default: return "checkmark.seal.fill"
        }
    }

    private var headerColor: Color {
        switch model.status {
        case .updateAvailable: return .blue
        case .motionUpdateAvailable: return .orange
        default: return .green
        }
    }

    private var headerTitle: String {
        switch model.status {
        case .updateAvailable: return "SpliceKit Motion Update Available"
        case .motionUpdateAvailable: return "Motion Updated"
        default: return "SpliceKit Motion Installed"
        }
    }

    private var headerSubtitle: String {
        switch model.status {
        case .updateAvailable:
            return "A newer version of SpliceKit Motion is ready to install."
        case .motionUpdateAvailable:
            return "Apple Motion has been updated. Rebuild the modded copy to use the latest version."
        default:
            return "Motion is ready to launch with enhanced features."
        }
    }
}
