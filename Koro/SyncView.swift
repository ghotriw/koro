import SwiftUI
import SwiftData

struct SyncView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = P2PManager.shared
    @State private var isActive = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Local Sync", isOn: $isActive)
                        .onChange(of: isActive) { _, active in
                            if active {
                                manager.start(modelContext: modelContext)
                            } else {
                                manager.stop()
                            }
                        }
                } footer: {
                    Text("Finds and syncs with Koro on other devices on the same Wi-Fi network. Keep this screen open during sync.")
                }

                if isActive {
                    Section("Nearby Devices") {
                        if manager.peers.isEmpty {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Looking for devices…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(manager.peers) { peer in
                                PeerRow(peer: peer)
                            }
                        }
                    }
                }

                Section("About Sync") {
                    LabeledContent("Device ID") {
                        Text(P2PManager.ownPeerUUID.uuidString.prefix(8) + "…")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                    }
                    LabeledContent("Ever Paired") {
                        Text(P2PManager.hasEverPaired ? "Yes" : "No")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear {
                manager.stop()
                isActive = false
            }
        }
    }
}

private struct PeerRow: View {
    let peer: PeerInfo

    var body: some View {
        HStack {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.body)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .transferring(let progress) = peer.state {
                CircularProgress(value: progress)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateIcon: String {
        switch peer.state {
        case .idle: return "circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .exchangingManifest: return "doc.badge.arrow.up"
        case .transferring: return "icloud.and.arrow.down"
        case .synced: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch peer.state {
        case .synced: return .green
        case .failed: return .red
        case .transferring: return .blue
        default: return .orange
        }
    }

    private var stateLabel: String {
        switch peer.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .exchangingManifest: return "Comparing libraries…"
        case .transferring(let p): return "Transferring \(Int(p * 100))%"
        case .synced: return "Up to date"
        case .failed(let msg): return "Error: \(msg)"
        }
    }
}

private struct CircularProgress: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: value)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: value)
        }
    }
}
