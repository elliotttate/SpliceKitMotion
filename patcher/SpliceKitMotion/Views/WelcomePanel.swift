import SwiftUI

struct WelcomePanel: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to SpliceKit Motion")
                .font(.title.bold())

            Text("SpliceKit Motion enhances Apple Motion with a JSON-RPC bridge and MCP server for programmatic control. Click Continue to patch your copy of Motion.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
                .frame(height: 8)

            // Motion version info
            if !model.motionVersion.isEmpty {
                Label {
                    Text("Motion v\(model.motionVersion)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
            } else {
                Label {
                    Text("Motion not found in /Applications")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline)

                Button {
                    model.browseForMotion()
                } label: {
                    Label("Browse for Motion...", systemImage: "folder")
                }
                .controlSize(.regular)
            }

            // Error display
            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.red.opacity(0.1))
                    .cornerRadius(6)
            }

            Spacer()

            // Action bar
            HStack {
                Spacer()
                Button {
                    model.patch()
                } label: {
                    Text("Continue")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.motionFound)
            }
        }
        .padding(24)
    }
}
