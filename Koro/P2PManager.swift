import Foundation
import MultipeerConnectivity
import UIKit
import SwiftData
import Combine

// MARK: - Peer state

enum PeerSyncState: Equatable {
    case idle
    case connecting
    case exchangingManifest
    case transferring(progress: Double)
    case synced
    case failed(String)
}

struct PeerInfo: Identifiable {
    let id: UUID          // remote peerUUID
    let displayName: String
    var state: PeerSyncState
}

// MARK: - P2PManager

/// Manages local-network discovery, connection, and sync lifecycle.
/// Call `start()` to activate and `stop()` to deactivate.
@MainActor
final class P2PManager: NSObject, ObservableObject {

    static let shared = P2PManager()

    // MARK: Published state

    @Published var peers: [PeerInfo] = []
    @Published var isSyncing = false

    // MARK: Private

    private let serviceType = "koro-sync"
    private var myPeerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    /// Maps MCPeerID.displayName → remote peerUUID (filled after handshake)
    private var peerUUIDs: [MCPeerID: UUID] = [:]
    /// Pending manifests waiting for diff: remote peerUUID → SyncManifest
    private var pendingManifests: [UUID: SyncManifest] = [:]
    /// SwiftData context for merge operations (injected via start)
    private var modelContext: ModelContext?

    // MARK: Identity

    /// Stable per-device UUID, reset if vendor ID changes (iCloud-restore mitigation).
    static var ownPeerUUID: UUID {
        let defaults = UserDefaults.standard
        let vendorKey = "koro.vendorID"
        let peerKey = "koro.peerUUID"
        let currentVendorID = UIDevice.current.identifierForVendor?.uuidString ?? ""

        if let stored = defaults.string(forKey: peerKey),
           let uuid = UUID(uuidString: stored),
           defaults.string(forKey: vendorKey) == currentVendorID {
            return uuid
        }
        // First launch or vendor ID mismatch (reinstall / iCloud restore on different device)
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: peerKey)
        defaults.set(currentVendorID, forKey: vendorKey)
        return fresh
    }

    static var hasEverPaired: Bool {
        get { UserDefaults.standard.bool(forKey: "koro.hasEverPaired") }
        set { UserDefaults.standard.set(newValue, forKey: "koro.hasEverPaired") }
    }

    // MARK: Lifecycle

    private override init() { super.init() }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        let deviceName = UIDevice.current.name
        myPeerID = MCPeerID(displayName: deviceName)

        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()

        print("🔵 P2P started — own ID: \(P2PManager.ownPeerUUID)")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        peers.removeAll()
    }

    // MARK: - Send helpers

    private func sendHandshake(to peerID: MCPeerID) {
        guard let context = modelContext else { return }
        guard let manifest = SyncManifest.build(from: context) else { return }

        let hello = HelloPayload(peerUUID: P2PManager.ownPeerUUID, manifest: manifest)
        guard let data = try? JSONEncoder().encode(hello) else { return }
        try? session.send(data, toPeers: [peerID], with: .reliable)
    }

    // MARK: - Merge entry point (called after receiving remote manifest)

    private func merge(remote: SyncManifest, remotePeerID: MCPeerID, remotePeerUUID: UUID) {
        guard let context = modelContext else { return }
        SyncEngine.merge(
            remote: remote,
            remotePeerUUID: remotePeerUUID,
            remotePeerID: remotePeerID,
            session: session,
            context: context,
            manager: self
        )
    }

    // MARK: - Internal state updaters (called from SyncEngine)

    func setPeerState(_ uuid: UUID, _ state: PeerSyncState) {
        if let idx = peers.firstIndex(where: { $0.id == uuid }) {
            peers[idx].state = state
        }
    }
}

// MARK: - MCSessionDelegate

extension P2PManager: MCSessionDelegate {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                print("🟢 Connected: \(peerID.displayName)")
                sendHandshake(to: peerID)

            case .notConnected:
                print("🔴 Disconnected: \(peerID.displayName)")
                if let uuid = peerUUIDs[peerID] {
                    peers.removeAll { $0.id == uuid }
                    peerUUIDs.removeValue(forKey: peerID)
                    pendingManifests.removeValue(forKey: uuid)
                }

            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            let decoder = JSONDecoder()

            // Try HelloPayload first (first message after connect)
            if let hello = try? decoder.decode(HelloPayload.self, from: data) {
                let uuid = hello.peerUUID
                peerUUIDs[peerID] = uuid

                if peers.firstIndex(where: { $0.id == uuid }) == nil {
                    peers.append(PeerInfo(id: uuid, displayName: peerID.displayName, state: .exchangingManifest))
                } else {
                    setPeerState(uuid, .exchangingManifest)
                }

                if !P2PManager.hasEverPaired {
                    P2PManager.hasEverPaired = true
                    print("🤝 First pairing — tombstones enabled")
                }

                merge(remote: hello.manifest, remotePeerID: peerID, remotePeerUUID: uuid)
                return
            }

            // Try WireMessage (tombstone signals, etc.)
            if let msg = try? decoder.decode(WireMessage.self, from: data), let context = modelContext {
                switch msg {
                case .tombstone(let record):
                    SyncEngine.handleTombstoneSignal(record, context: context)
                }
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        Task { @MainActor in
            guard let uuid = peerUUIDs[peerID] else { return }
            setPeerState(uuid, .transferring(progress: progress.fractionCompleted))
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        Task { @MainActor in
            guard let uuid = peerUUIDs[peerID] else { return }
            if let error {
                setPeerState(uuid, .failed(error.localizedDescription))
                return
            }
            guard let localURL else { return }
            SyncEngine.handleReceivedResource(
                name: resourceName,
                at: localURL,
                fromPeerUUID: uuid,
                context: modelContext!,
                manager: self
            )
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension P2PManager: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            invitationHandler(true, session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("⚠️ Advertiser failed: \(error)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension P2PManager: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            if let uuid = peerUUIDs[peerID] {
                peers.removeAll { $0.id == uuid }
                peerUUIDs.removeValue(forKey: peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("⚠️ Browser failed: \(error)")
    }
}

// MARK: - Wire payload

private struct HelloPayload: Codable {
    let peerUUID: UUID
    let manifest: SyncManifest
}
