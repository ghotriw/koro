import SwiftUI
import SwiftData

struct SyncView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = P2PManager.shared
    @State private var isActive = false
    @ObservedObject private var logger = SyncLogger.shared
    @ObservedObject private var netMonitor = NetworkMonitor.shared

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

                Section {
                    LabeledContent("Device ID") {
                        Text(P2PManager.ownPeerUUID.uuidString.prefix(8) + "…")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                    }
                    LabeledContent("Ever Paired") {
                        Text(P2PManager.hasEverPaired ? "Yes" : "No")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Local Network") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(netMonitor.isWiFi ? Color.green : (netMonitor.isConnected ? Color.orange : Color.red))
                                .frame(width: 8, height: 8)
                            if let ip = netMonitor.localIP {
                                Text("\(netMonitor.interfaceName) (\(ip))")
                            } else {
                                Text(netMonitor.interfaceName)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Sync Mode") {
                        Text(manager.estimatedTransport.displayName)
                            .foregroundStyle(manager.estimatedTransport.isBluetooth ? .orange : .secondary)
                    }
                    if let speed = manager.lastTransferSpeed {
                        LabeledContent("Transfer Speed") {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("About Sync")
                } footer: {
                    if manager.estimatedTransport.isBluetooth {
                        Text("⚠️ Low transfer speed detected. Sync appears to be running over Bluetooth instead of Wi-Fi. Ensure both devices are connected to the same Wi-Fi network and Local Network access is allowed in iOS Settings.")
                            .foregroundStyle(.orange)
                    }
                }
                
                if !logger.logs.isEmpty {
                    Section {
                        ScrollView {
                            Text(logger.logs.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .frame(height: 200)
                    } header: {
                        HStack {
                            Text("Diagnostics Log")
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = logger.logs.joined(separator: "\n")
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if !logger.logs.isEmpty {
                        Button("Clear") { logger.clear() }
                    }
                }
            }
            .onAppear {
                netMonitor.refresh()
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

            if case .transferring(let completed, let total) = peer.state, total > 0 {
                CircularProgress(value: Double(completed) / Double(total))
                    .frame(width: 32, height: 32)
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
        case .transferring(let completed, let total):
            let pct = total > 0 ? Int((Double(completed) / Double(total)) * 100) : 0
            if total > 0 {
                return "Syncing: \(completed) of \(total) items • \(pct)%"
            } else {
                return "Syncing…"
            }
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
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(1.0, max(0.0, value))))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: value)
            Text("\(Int(min(1.0, max(0.0, value)) * 100))%")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}
