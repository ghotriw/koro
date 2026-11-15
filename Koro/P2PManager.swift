import Foundation
import Network
import UIKit
import SwiftData
import Combine

// MARK: - Sync Logging

@MainActor
final class SyncLogger: ObservableObject {
    static let shared = SyncLogger()
    @Published var logs: [String] = []
    
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let formatted = "[\(timestamp)] \(message)"
        print(formatted)
        logs.append(formatted)
    }
    
    func clear() {
        logs.removeAll()
    }
}

func syncLog(_ message: String) {
    Task { @MainActor in
        SyncLogger.shared.log(message)
    }
}

// MARK: - Peer state

enum PeerSyncState: Equatable {
    case idle
    case connecting
    case exchangingManifest
    case transferring(completed: Int, total: Int)
    case synced
    case failed(String)
}

struct PeerInfo: Identifiable {
    let id: UUID          // remote peerUUID
    var displayName: String
    var state: PeerSyncState
}

enum EstimatedTransport: Equatable {
    case idle
    case measuring
    case wifi(speed: Double)
    case bluetooth(speed: Double)

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .measuring:
            return "Measuring…"
        case .wifi(let speed):
            let s = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
            return "⚡ Wi-Fi (\(s))"
        case .bluetooth(let speed):
            let s = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
            return "🐢 Bluetooth (\(s))"
        }
    }

    var isBluetooth: Bool {
        if case .bluetooth = self { return true }
        return false
    }
}

// MARK: - Wire payload

struct HelloPayload: Codable {
    let peerUUID: UUID
    let displayName: String
    let manifest: SyncManifest
}

// MARK: - P2PManager

/// Manages local-network discovery, connection, and sync lifecycle using Apple Network.framework (TN3213).
@MainActor
final class P2PManager: NSObject, ObservableObject {

    static let shared = P2PManager()

    // MARK: Published state

    @Published var peers: [PeerInfo] = []
    @Published var isSyncing = false
    @Published var estimatedTransport: EstimatedTransport = .idle
    @Published var lastTransferSpeed: Double? = nil
    @Published var activeTransfersCount: Int = 0

    // MARK: Private

    /// Primary type plus `_http._tcp` fallback: hosts like LiveContainer only allow Bonjour types from
    /// their own Info.plist allowlist, which includes `_http._tcp` but not ours. Discovery on `_http._tcp`
    /// is therefore strictly filtered by the TXT marker below.
    private let serviceTypes = ["_koro-sync._tcp", "_http._tcp"]
    private static let txtMarkerKey = "koro"
    private static let txtMarkerValue = "1"
    private var listeners: [NWListener] = []
    private var browsers: [NWBrowser] = []
    private let networkQueue = DispatchQueue(label: "com.koro.p2p.network", qos: .userInitiated)

    var activeConnections: [UUID: PeerConnection] = [:]
    var pendingConnections: [PeerConnection] = []
    /// Peers we currently have an outbound attempt (connecting or awaiting Hello) for.
    var pendingOutboundPeerIDs: Set<UUID> = []
    /// Candidate endpoints per service type, keyed by peer id. One peer may appear under several types.
    private var discovered: [String: [UUID: (name: String, endpoint: NWEndpoint)]] = [:]
    /// Endpoints that already failed for a peer; the next attempt falls through to another service type.
    private var failedEndpoints: [UUID: Set<NWEndpoint>] = [:]
    private(set) var modelContext: ModelContext?
    private var resourceStartTimes: [String: Date] = [:]
    private var sessionBytesTransferred: Int64 = 0
    private var sessionTransferStartTime: Date?

    // MARK: Identity

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
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: peerKey)
        defaults.set(currentVendorID, forKey: vendorKey)
        return fresh
    }

    static var hasEverPaired: Bool {
        get { UserDefaults.standard.bool(forKey: "koro.hasEverPaired") }
        set { UserDefaults.standard.set(newValue, forKey: "koro.hasEverPaired") }
    }

    private override init() { super.init() }

    // MARK: - Lifecycle

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        estimatedTransport = .idle
        lastTransferSpeed = nil
        activeTransfersCount = 0
        resourceStartTimes.removeAll()
        activeConnections.removeAll()
        pendingConnections.removeAll()
        pendingOutboundPeerIDs.removeAll()
        discovered.removeAll()
        failedEndpoints.removeAll()
        peers.removeAll()

        syncLog("🔵 P2P started — own ID: \(P2PManager.ownPeerUUID) [Network.framework]")
        for type in serviceTypes {
            startListener(type: type)
            startBrowser(type: type)
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        browsers.forEach { $0.cancel() }
        browsers.removeAll()

        for conn in activeConnections.values {
            conn.cancel()
        }
        activeConnections.removeAll()
        for conn in pendingConnections {
            conn.cancel()
        }
        pendingConnections.removeAll()
        pendingOutboundPeerIDs.removeAll()
        discovered.removeAll()
        failedEndpoints.removeAll()
        peers.removeAll()
        resourceStartTimes.removeAll()
        activeTransfersCount = 0
        syncLog("🔴 P2P stopped")
    }

    // MARK: - Listener & Browser

    private func createNetworkParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true
        // Fail a SYN sent into the void (peer left Wi-Fi, stale Bonjour record) in seconds instead of ~75 s,
        // so the .waiting/.failed handling and endpoint fallback kick in quickly.
        tcpOptions.connectionTimeout = 10

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }

    private func createBrowserParameters() -> NWParameters {
        let params = NWParameters()
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }

    private func startListener(type serviceType: String) {
        do {
            let params = createNetworkParameters()
            let l = try NWListener(using: params)
            var txt = NWTXTRecord()
            txt[P2PManager.txtMarkerKey] = P2PManager.txtMarkerValue
            txt["id"] = P2PManager.ownPeerUUID.uuidString
            l.service = NWListener.Service(name: UIDevice.current.name, type: serviceType, txtRecord: txt)

            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        syncLog("🎧 NWListener ready and advertising \(UIDevice.current.name) [\(serviceType)]")
                    case .waiting(let error):
                        syncLog("⏳ NWListener waiting [\(serviceType)]: \(error)")
                    case .failed(let error):
                        syncLog("⚠️ NWListener failed [\(serviceType)]: \(error)")
                    default:
                        break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] inboundConn in
                Task { @MainActor [weak self] in
                    self?.handleInboundConnection(inboundConn)
                }
            }

            l.start(queue: networkQueue)
            self.listeners.append(l)
        } catch {
            syncLog("❌ Failed to create NWListener: \(error)")
        }
    }

    private func startBrowser(type serviceType: String) {
        let params = createBrowserParameters()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)

        b.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    syncLog("🔍 NWBrowser searching for peers on Wi-Fi… [\(serviceType)]")
                case .waiting(let error):
                    syncLog("⏳ NWBrowser waiting [\(serviceType)]: \(error)")
                case .failed(let error):
                    syncLog("⚠️ NWBrowser failed [\(serviceType)]: \(error)")
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                syncLog("🔍 NWBrowser update [\(serviceType)]: \(results.count) result(s)")
                self?.handleDiscoveredEndpoints(results, type: serviceType)
            }
        }

        b.start(queue: networkQueue)
        self.browsers.append(b)
    }

    private func handleDiscoveredEndpoints(_ results: Set<NWBrowser.Result>, type: String) {
        let ownID = P2PManager.ownPeerUUID
        var found: [UUID: (name: String, endpoint: NWEndpoint)] = [:]

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            // Strict filter: only services carrying our TXT marker and a valid peer id.
            // Mandatory because `_http._tcp` is shared with printers, routers, NAS, etc.
            guard case .bonjour(let txt) = result.metadata,
                  txt[P2PManager.txtMarkerKey] == P2PManager.txtMarkerValue,
                  let idStr = txt["id"], let remoteID = UUID(uuidString: idStr) else { continue }

            if remoteID == ownID { continue }

            // Deterministic initiator: device with the greater peer UUID initiates connection
            if ownID.uuidString < remoteID.uuidString {
                syncLog("⏳ Discovered \(name) [\(type)] — waiting for remote to connect (their ID is greater)")
                continue
            }
            found[remoteID] = (name, result.endpoint)
        }
        discovered[type] = found

        // A fresh browse update gives previously failed endpoints another chance (unless an attempt is running).
        failedEndpoints = failedEndpoints.filter { pendingOutboundPeerIDs.contains($0.key) }

        for id in Set(discovered.values.flatMap { $0.keys }) {
            connectIfNeeded(peerID: id)
        }
    }

    /// Starts one outbound attempt for the peer, using the first service type whose endpoint hasn't failed yet.
    private func connectIfNeeded(peerID: UUID) {
        guard activeConnections[peerID] == nil, !pendingOutboundPeerIDs.contains(peerID) else { return }
        let failed = failedEndpoints[peerID] ?? []
        for type in serviceTypes {
            guard let candidate = discovered[type]?[peerID], !failed.contains(candidate.endpoint) else { continue }
            syncLog("🎯 Discovered peer: \(candidate.name) [\(type)] — connecting…")
            pendingOutboundPeerIDs.insert(peerID)
            connect(to: candidate.endpoint, displayName: candidate.name, expectedPeerID: peerID)
            return
        }
    }

    /// Called when an outbound attempt ended before a valid Hello; falls back to the peer's other service type.
    func outboundAttemptFailed(peerID: UUID, endpoint: NWEndpoint) {
        failedEndpoints[peerID, default: []].insert(endpoint)
        connectIfNeeded(peerID: peerID)
    }

    private func connect(to endpoint: NWEndpoint, displayName: String, expectedPeerID: UUID) {
        let params = createNetworkParameters()
        let conn = NWConnection(to: endpoint, using: params)
        let peerConn = PeerConnection(connection: conn, displayName: displayName, endpoint: endpoint, isOutbound: true, manager: self)
        peerConn.expectedPeerID = expectedPeerID
        pendingConnections.append(peerConn)
        peerConn.start()
    }

    /// Checks done before a listener answers with its own Hello (no manifest for self/duplicate connections).
    func shouldAccept(hello: HelloPayload, connection: PeerConnection) -> Bool {
        if hello.peerUUID == P2PManager.ownPeerUUID { return false }
        if let existing = activeConnections[hello.peerUUID], existing !== connection {
            // Only the device with the greater UUID initiates, so a fresh inbound connection means the peer
            // already dropped the old one (e.g. app restart) — replace it. Outbound duplicates are dropped.
            guard !connection.isOutbound else { return false }
            syncLog("♻️ Replacing stale connection with \(hello.displayName)")
            activeConnections.removeValue(forKey: hello.peerUUID)
            existing.cancel()
        }
        return true
    }

    private func handleInboundConnection(_ conn: NWConnection) {
        let peerConn = PeerConnection(connection: conn, displayName: "Remote Device", isOutbound: false, manager: self)
        pendingConnections.append(peerConn)
        peerConn.start()
    }

    // MARK: - Handshake & Tie-breaking

    func handlePeerHello(hello: HelloPayload, connection: PeerConnection) {
        pendingConnections.removeAll { $0 === connection }
        let remoteUUID = hello.peerUUID
        if remoteUUID == P2PManager.ownPeerUUID {
            connection.cancel()
            return
        }
        let remoteName = hello.displayName
        connection.displayName = remoteName

        if let existing = activeConnections[remoteUUID], existing !== connection {
            syncLog("🔀 Active connection with \(remoteName) already established — dropping duplicate connection")
            connection.cancel()
            return
        }

        activeConnections[remoteUUID] = connection

        if let idx = peers.firstIndex(where: { $0.id == remoteUUID }) {
            peers[idx].displayName = remoteName
            peers[idx].state = .exchangingManifest
        } else {
            peers.append(PeerInfo(id: remoteUUID, displayName: remoteName, state: .exchangingManifest))
        }

        if !P2PManager.hasEverPaired {
            P2PManager.hasEverPaired = true
            syncLog("🤝 First pairing — tombstones enabled")
        }

        guard let context = modelContext else { return }
        SyncEngine.merge(
            remote: hello.manifest,
            remotePeerUUID: remoteUUID,
            context: context,
            manager: self
        )
    }

    // MARK: - Send Resource

    func sendResource(at fileURL: URL, withName resourceName: String, to peerUUID: UUID, completion: @escaping (Error?) -> Void) {
        guard let connection = activeConnections[peerUUID] else {
            completion(NSError(domain: "P2PManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active connection to peer"]))
            return
        }
        connection.sendResource(at: fileURL, name: resourceName, completion: completion)
    }

    // MARK: - Internal state updaters

    func setPeerState(_ uuid: UUID, _ state: PeerSyncState) {
        if let idx = peers.firstIndex(where: { $0.id == uuid }) {
            peers[idx].state = state
        }
    }

    func recordTransferStart(name: String) {
        if sessionTransferStartTime == nil {
            sessionTransferStartTime = Date()
            sessionBytesTransferred = 0
        }
        resourceStartTimes[name] = Date()
        activeTransfersCount += 1
        if estimatedTransport == .idle {
            estimatedTransport = .measuring
        }
    }

    func recordTransferMetric(bytes: Int64, duration: TimeInterval, name: String) {
        activeTransfersCount = max(0, activeTransfersCount - 1)
        sessionBytesTransferred += bytes

        if sessionTransferStartTime == nil {
            sessionTransferStartTime = Date().addingTimeInterval(-duration)
        }
        let sessionElapsed = sessionTransferStartTime.map { Date().timeIntervalSince($0) } ?? duration
        let speed = sessionElapsed > 0.05 ? Double(sessionBytesTransferred) / sessionElapsed : Double(bytes) / max(0.001, duration)

        lastTransferSpeed = speed
        estimatedTransport = .wifi(speed: speed)

        if activeTransfersCount == 0 {
            sessionTransferStartTime = nil
            sessionBytesTransferred = 0
        }

        let speedStr = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
        let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        syncLog("📊 Transfer metric: \(name) (\(sizeStr) in \(String(format: "%.1f", duration))s @ \(speedStr)) → \(estimatedTransport.displayName)")
    }
}

// MARK: - PeerConnection

final class PeerConnection: @unchecked Sendable {
    let connection: NWConnection
    var displayName: String
    let endpoint: NWEndpoint?
    let isOutbound: Bool
    weak var manager: P2PManager?
    var peerUUID: UUID?
    var expectedPeerID: UUID?
    private let finishLock = NSLock()
    private var finished = false
    private var _receivedHello = false
    private var connectTimer: DispatchWorkItem?

    /// Written on the connection queue, read from any thread — guarded by `finishLock`.
    private var receivedHello: Bool {
        get { finishLock.lock(); defer { finishLock.unlock() }; return _receivedHello }
        set { finishLock.lock(); _receivedHello = newValue; finishLock.unlock() }
    }

    // Protocol limits — frames from non-Koro clients (e.g. HTTP on `_http._tcp`) are rejected early.
    private static let helloTimeout: TimeInterval = 10
    /// How long a connection may sit in `.waiting` (unreachable/stale endpoint) before we give up and try the next one.
    private static let connectTimeout: TimeInterval = 12
    private static let maxHelloSize: UInt64 = 16 * 1024 * 1024
    private static let maxHeaderSize: UInt32 = 4096
    // Wire format: "KORO" magic (4) | version (1) | type (1) | headerLen u32 BE (4) | dataLen u64 BE (8)
    static let frameMagic: [UInt8] = [0x4B, 0x4F, 0x52, 0x4F]
    static let protocolVersion: UInt8 = 1
    static let frameHeaderSize = 18

    static func makeFrameHeader(type: UInt8, headerLen: UInt32, dataLen: UInt64) -> Data {
        var d = Data(frameMagic)
        d.append(protocolVersion)
        d.append(type)
        withUnsafeBytes(of: headerLen.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: dataLen.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    private static let maxResourceSize: UInt64 = 1024 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.koro.p2p.peerconnection", qos: .userInitiated)

    init(connection: NWConnection, displayName: String, endpoint: NWEndpoint? = nil, isOutbound: Bool, manager: P2PManager) {
        self.connection = connection
        self.displayName = displayName
        self.endpoint = endpoint
        self.isOutbound = isOutbound
        self.manager = manager
    }

    func start() {
        syncLog("⏳ Connecting to \(displayName)…")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                syncLog("🟢 Connected: \(self.displayName)")
                self.connectTimer?.cancel()
                self.connectTimer = nil
                // Start the Hello timer only now: while a Local Network prompt is open the connection
                // legitimately sits in .waiting for longer than the timeout.
                self.queue.asyncAfter(deadline: .now() + PeerConnection.helloTimeout) { [weak self] in
                    guard let self, !self.receivedHello else { return }
                    syncLog("⏱ No valid Hello from \(self.displayName) — dropping")
                    self.cancel(retryOtherEndpoint: true)
                }
                Task { @MainActor in
                    self.handleConnected()
                }
            case .waiting(let error):
                syncLog("⏳ Connection waiting with \(self.displayName): \(error)")
                self.armConnectTimerIfNeeded(for: error)
            case .failed(let error):
                syncLog("⚠️ Connection error with \(self.displayName): \(error)")
                self.handleDisconnect()
            case .cancelled:
                self.handleDisconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// NWConnection often stays in `.waiting` (ECONNREFUSED/ETIMEDOUT) instead of failing, e.g. for a stale Bonjour
    /// record. Without a timeout such an attempt would block the peer forever and the fallback endpoint would
    /// never be tried. PolicyDenied (-65570) is the exception: it means the Local Network prompt is still open
    /// (or permission is missing), so we keep waiting.
    private func armConnectTimerIfNeeded(for error: NWError) {
        if case .dns(let code) = error, code == -65570 { return }
        queue.async { [weak self] in
            guard let self, self.connectTimer == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.connection.state != .ready else { return }
                syncLog("⏱ Connection to \(self.displayName) still not ready — trying next endpoint")
                self.cancel(retryOtherEndpoint: true)
            }
            self.connectTimer = item
            self.queue.asyncAfter(deadline: .now() + PeerConnection.connectTimeout, execute: item)
        }
    }

    /// Explicitly closes the connection. Pass `retryOtherEndpoint` to let the manager fall back to
    /// the peer's other service type (only meaningful for outbound attempts that never got a Hello).
    func cancel(retryOtherEndpoint: Bool = false) {
        connection.cancel()
        cleanup(retry: retryOtherEndpoint)
    }

    private func handleDisconnect() {
        cleanup(retry: true)
    }

    /// Single teardown path (idempotent): drops pending/active bookkeeping once.
    private func cleanup(retry: Bool) {
        finishLock.lock()
        let alreadyFinished = finished
        finished = true
        finishLock.unlock()
        if alreadyFinished { return }

        // connectTimer is owned by `queue`; cancel it there to avoid racing the writer.
        queue.async { [weak self] in
            self?.connectTimer?.cancel()
            self?.connectTimer = nil
        }
        let helloDone = receivedHello
        Task { @MainActor in
            guard let manager = self.manager else { return }
            manager.pendingConnections.removeAll { $0 === self }
            if let id = self.expectedPeerID { manager.pendingOutboundPeerIDs.remove(id) }
            if let uuid = self.peerUUID, manager.activeConnections[uuid] === self {
                manager.activeConnections.removeValue(forKey: uuid)
                manager.peers.removeAll { $0.id == uuid }
                syncLog("🔴 Disconnected: \(self.displayName)")
            }
            if retry, self.isOutbound, !helloDone, let id = self.expectedPeerID, let ep = self.endpoint {
                manager.outboundAttemptFailed(peerID: id, endpoint: ep)
            }
        }
    }

    @MainActor
    private func handleConnected() {
        // Only the initiator speaks first; the listener answers after a valid Hello arrives.
        if isOutbound {
            guard let manager = self.manager, let context = manager.modelContext,
                  let manifest = SyncManifest.build(from: context) else { return }
            sendHello(manifest: manifest)
        }
        startReceiving()
    }

    // MARK: - Framing & Sending

    func sendHello(manifest: SyncManifest) {
        let payload = HelloPayload(
            peerUUID: P2PManager.ownPeerUUID,
            displayName: UIDevice.current.name,
            manifest: manifest
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let headerLen: UInt32 = 0
        let dataLen = UInt64(data.count)

        var frame = PeerConnection.makeFrameHeader(type: 0x01, headerLen: headerLen, dataLen: dataLen)
        frame.append(data)

        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                syncLog("❌ Failed to send hello: \(error)")
            }
        })
    }

    func sendResource(at fileURL: URL, name: String, completion: @escaping (Error?) -> Void) {
        let sendStart = Date()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(NSError(domain: "PeerConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "File missing"]))
            return
        }

        let nameData = name.data(using: .utf8) ?? Data()
        let headerLen = UInt32(nameData.count)
        let dataLen = UInt64(fileData.count)

        var frame = PeerConnection.makeFrameHeader(type: 0x02, headerLen: headerLen, dataLen: dataLen)
        frame.append(nameData)
        frame.append(fileData)

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            let duration = Date().timeIntervalSince(sendStart)
            if error == nil {
                Task { @MainActor [weak self] in
                    self?.manager?.recordTransferMetric(bytes: fileSize, duration: duration, name: name)
                }
            }
            completion(error)
        })
    }

    // MARK: - Receiving

    func startReceiving() {
        receiveHeader()
    }

    private func receiveHeader() {
        let size = PeerConnection.frameHeaderSize
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.handleDisconnect()
                return
            }
            guard let content, content.count == size else {
                if isComplete { self.handleDisconnect() }
                return
            }

            let bytes = [UInt8](content)
            guard Array(bytes[0..<4]) == PeerConnection.frameMagic else {
                syncLog("🚫 Not a Koro peer (bad magic) from \(self.displayName) — dropping")
                self.cancel()
                return
            }
            guard bytes[4] == PeerConnection.protocolVersion else {
                syncLog("🚫 Incompatible protocol version \(bytes[4]) (ours \(PeerConnection.protocolVersion)) from \(self.displayName) — dropping")
                self.cancel()
                return
            }

            let type = bytes[5]
            let headerLen = bytes[6..<10].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let dataLen = bytes[10..<18].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

            // Validate before converting to Int (UInt64 -> Int traps above Int.max).
            let valid: Bool
            if !self.receivedHello {
                valid = type == 0x01 && headerLen == 0 && dataLen > 0 && dataLen <= PeerConnection.maxHelloSize
            } else {
                switch type {
                case 0x01: valid = headerLen == 0 && dataLen > 0 && dataLen <= PeerConnection.maxHelloSize
                case 0x02: valid = headerLen <= PeerConnection.maxHeaderSize && dataLen <= PeerConnection.maxResourceSize
                default: valid = false
                }
            }
            guard valid else {
                syncLog("🚫 Invalid frame from \(self.displayName) (type \(type), \(dataLen) bytes) — dropping")
                self.cancel()
                return
            }

            self.receivePayload(type: type, headerLen: Int(headerLen), dataLen: Int(dataLen))
        }
    }

    private func receivePayload(type: UInt8, headerLen: Int, dataLen: Int) {
        if headerLen > 0 {
            readExact(count: headerLen, toFile: nil) { [weak self] headerData, error in
                guard let self, let headerData else { self?.handleDisconnect(); return }
                self.receiveData(type: type, headerData: headerData, dataLen: dataLen)
            }
        } else {
            self.receiveData(type: type, headerData: Data(), dataLen: dataLen)
        }
    }

    private func receiveData(type: UInt8, headerData: Data, dataLen: Int) {
        if type == 0x01 { // Hello
            readExact(count: dataLen, toFile: nil) { [weak self] bodyData, error in
                guard let self, let bodyData else { self?.handleDisconnect(); return }
                guard let hello = try? JSONDecoder().decode(HelloPayload.self, from: bodyData) else {
                    syncLog("🚫 Malformed Hello from \(self.displayName) — dropping")
                    self.cancel()
                    return
                }
                if let expected = self.expectedPeerID, expected != hello.peerUUID {
                    syncLog("🚫 Hello id mismatch from \(self.displayName) — dropping")
                    self.cancel()
                    return
                }
                self.receivedHello = true
                Task { @MainActor in
                    self.peerUUID = hello.peerUUID
                    self.displayName = hello.displayName
                    // Listener side: reply with our Hello first so it precedes any sync traffic.
                    if !self.isOutbound {
                        guard self.manager?.shouldAccept(hello: hello, connection: self) == true else {
                            syncLog("🔀 Rejecting \(hello.displayName) before replying (self)")
                            self.cancel()
                            return
                        }
                        if let context = self.manager?.modelContext,
                           let manifest = SyncManifest.build(from: context) {
                            self.sendHello(manifest: manifest)
                        }
                    }
                    self.manager?.handlePeerHello(hello: hello, connection: self)
                }
                self.receiveHeader()
            }
        } else if type == 0x02 { // Resource
            let resourceName = String(data: headerData, encoding: .utf8) ?? ""
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let fileHandle = try? FileHandle(forWritingTo: tempURL) else {
                self.handleDisconnect()
                return
            }
            let receiveStart = Date()
            Task { @MainActor in
                self.manager?.recordTransferStart(name: resourceName)
            }
            readExact(count: dataLen, toFile: fileHandle) { [weak self] _, error in
                guard let self else { return }
                try? fileHandle.close()
                if error == nil {
                    let duration = Date().timeIntervalSince(receiveStart)
                    Task { @MainActor in
                        self.manager?.recordTransferMetric(bytes: Int64(dataLen), duration: duration, name: resourceName)
                        if let peerUUID = self.peerUUID, let context = self.manager?.modelContext {
                            SyncEngine.handleReceivedResource(
                                name: resourceName,
                                at: tempURL,
                                fromPeerUUID: peerUUID,
                                context: context,
                                manager: self.manager!
                            )
                        }
                    }
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                self.receiveHeader()
            }
        } else {
            readExact(count: dataLen, toFile: nil) { [weak self] _, _ in
                self?.receiveHeader()
            }
        }
    }

    private func readExact(count: Int, toFile: FileHandle?, completion: @escaping (Data?, Error?) -> Void) {
        guard count > 0 else {
            completion(Data(), nil)
            return
        }
        var remaining = count
        var buffer = (toFile == nil) ? Data(capacity: min(count, 512 * 1024)) : nil

        func nextChunk() {
            let toRead = min(remaining, 64 * 1024)
            connection.receive(minimumIncompleteLength: 1, maximumLength: toRead) { [weak self] data, _, isComplete, error in
                guard self != nil else { return }
                if let error {
                    completion(nil, error)
                    return
                }
                guard let data, !data.isEmpty else {
                    if isComplete {
                        completion(nil, NSError(domain: "PeerConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream closed unexpectedly"]))
                    }
                    return
                }

                if let toFile {
                    try? toFile.write(contentsOf: data)
                } else {
                    buffer?.append(data)
                }

                remaining -= data.count
                if remaining <= 0 {
                    completion(buffer, nil)
                } else {
                    nextChunk()
                }
            }
        }
        nextChunk()
    }
}
