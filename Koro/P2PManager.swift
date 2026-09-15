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

    private let serviceType = "_koro-sync._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let networkQueue = DispatchQueue(label: "com.koro.p2p.network", qos: .userInitiated)

    var activeConnections: [UUID: PeerConnection] = [:]
    var pendingConnections: [PeerConnection] = []
    var pendingOutboundEndpoints: Set<NWEndpoint> = []
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
        pendingOutboundEndpoints.removeAll()
        peers.removeAll()

        syncLog("🔵 P2P started — own ID: \(P2PManager.ownPeerUUID) [Network.framework]")
        startListener()
        startBrowser()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil

        for conn in activeConnections.values {
            conn.cancel()
        }
        activeConnections.removeAll()
        for conn in pendingConnections {
            conn.cancel()
        }
        pendingConnections.removeAll()
        pendingOutboundEndpoints.removeAll()
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

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }

    private func createBrowserParameters() -> NWParameters {
        let params = NWParameters()
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }

    private func startListener() {
        do {
            let params = createNetworkParameters()
            let l = try NWListener(using: params)
            var txt = NWTXTRecord()
            txt["id"] = P2PManager.ownPeerUUID.uuidString
            l.service = NWListener.Service(name: UIDevice.current.name, type: serviceType, txtRecord: txt)

            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        syncLog("🎧 NWListener ready and advertising \(UIDevice.current.name)")
                    case .waiting(let error):
                        syncLog("⏳ NWListener waiting: \(error)")
                    case .failed(let error):
                        syncLog("⚠️ NWListener failed: \(error)")
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
            self.listener = l
        } catch {
            syncLog("❌ Failed to create NWListener: \(error)")
        }
    }

    private func startBrowser() {
        let params = createBrowserParameters()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)

        b.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    syncLog("🔍 NWBrowser searching for peers on Wi-Fi…")
                case .waiting(let error):
                    syncLog("⏳ NWBrowser waiting: \(error)")
                case .failed(let error):
                    syncLog("⚠️ NWBrowser failed: \(error)")
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                syncLog("🔍 NWBrowser update: \(results.count) peer(s) found")
                self?.handleDiscoveredEndpoints(results)
            }
        }

        b.start(queue: networkQueue)
        self.browser = b
    }

    private func handleDiscoveredEndpoints(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else {
                continue
            }
            if name == UIDevice.current.name {
                continue
            }
            if pendingOutboundEndpoints.contains(result.endpoint) { continue }
            if activeConnections.values.contains(where: { $0.displayName == name }) { continue }

            // Deterministic initiator: device with the greater peer UUID initiates connection
            if case .bonjour(let txt) = result.metadata, let remoteUUIDStr = txt["id"] {
                let ownUUIDStr = P2PManager.ownPeerUUID.uuidString
                if ownUUIDStr < remoteUUIDStr {
                    syncLog("⏳ Discovered \(name) — waiting for remote to connect (their ID is greater)")
                    continue
                }
            }

            syncLog("🎯 Discovered peer: \(name) — connecting…")
            pendingOutboundEndpoints.insert(result.endpoint)
            connect(to: result.endpoint, displayName: name)
        }
    }

    private func connect(to endpoint: NWEndpoint, displayName: String) {
        let params = createNetworkParameters()
        let conn = NWConnection(to: endpoint, using: params)
        let peerConn = PeerConnection(connection: conn, displayName: displayName, endpoint: endpoint, isOutbound: true, manager: self)
        pendingConnections.append(peerConn)
        peerConn.start()
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
                Task { @MainActor in
                    self.handleConnected()
                }
            case .waiting(let error):
                syncLog("⏳ Connection waiting with \(self.displayName): \(error)")
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

    func cancel() {
        connection.cancel()
        Task { @MainActor in
            self.manager?.pendingConnections.removeAll { $0 === self }
            if let ep = self.endpoint {
                self.manager?.pendingOutboundEndpoints.remove(ep)
            }
            if let uuid = self.peerUUID, self.manager?.activeConnections[uuid] === self {
                self.manager?.activeConnections.removeValue(forKey: uuid)
                self.manager?.peers.removeAll { $0.id == uuid }
                syncLog("🔴 Disconnected: \(self.displayName)")
            }
        }
    }

    @MainActor
    private func handleConnected() {
        guard let manager = self.manager, let context = manager.modelContext,
              let manifest = SyncManifest.build(from: context) else { return }
        sendHello(manifest: manifest)
        startReceiving()
    }

    private func handleDisconnect() {
        Task { @MainActor in
            self.manager?.pendingConnections.removeAll { $0 === self }
            if let ep = self.endpoint {
                self.manager?.pendingOutboundEndpoints.remove(ep)
            }
            if let uuid = self.peerUUID, self.manager?.activeConnections[uuid] === self {
                self.manager?.activeConnections.removeValue(forKey: uuid)
                self.manager?.peers.removeAll { $0.id == uuid }
                syncLog("🔴 Disconnected: \(self.displayName)")
            }
        }
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

        var frame = Data(count: 13)
        frame[0] = 0x01
        frame[1] = UInt8((headerLen >> 24) & 0xFF)
        frame[2] = UInt8((headerLen >> 16) & 0xFF)
        frame[3] = UInt8((headerLen >> 8) & 0xFF)
        frame[4] = UInt8(headerLen & 0xFF)

        frame[5] = UInt8((dataLen >> 56) & 0xFF)
        frame[6] = UInt8((dataLen >> 48) & 0xFF)
        frame[7] = UInt8((dataLen >> 40) & 0xFF)
        frame[8] = UInt8((dataLen >> 32) & 0xFF)
        frame[9] = UInt8((dataLen >> 24) & 0xFF)
        frame[10] = UInt8((dataLen >> 16) & 0xFF)
        frame[11] = UInt8((dataLen >> 8) & 0xFF)
        frame[12] = UInt8(dataLen & 0xFF)

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

        var frame = Data(count: 13)
        frame[0] = 0x02
        frame[1] = UInt8((headerLen >> 24) & 0xFF)
        frame[2] = UInt8((headerLen >> 16) & 0xFF)
        frame[3] = UInt8((headerLen >> 8) & 0xFF)
        frame[4] = UInt8(headerLen & 0xFF)

        frame[5] = UInt8((dataLen >> 56) & 0xFF)
        frame[6] = UInt8((dataLen >> 48) & 0xFF)
        frame[7] = UInt8((dataLen >> 40) & 0xFF)
        frame[8] = UInt8((dataLen >> 32) & 0xFF)
        frame[9] = UInt8((dataLen >> 24) & 0xFF)
        frame[10] = UInt8((dataLen >> 16) & 0xFF)
        frame[11] = UInt8((dataLen >> 8) & 0xFF)
        frame[12] = UInt8(dataLen & 0xFF)

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
        connection.receive(minimumIncompleteLength: 13, maximumLength: 13) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.handleDisconnect()
                return
            }
            guard let content, content.count == 13 else {
                if isComplete { self.handleDisconnect() }
                return
            }

            let type = content[0]
            let headerLen = (UInt32(content[1]) << 24)
                          | (UInt32(content[2]) << 16)
                          | (UInt32(content[3]) << 8)
                          | (UInt32(content[4]))

            let dataLen = (UInt64(content[5]) << 56)
                        | (UInt64(content[6]) << 48)
                        | (UInt64(content[7]) << 40)
                        | (UInt64(content[8]) << 32)
                        | (UInt64(content[9]) << 24)
                        | (UInt64(content[10]) << 16)
                        | (UInt64(content[11]) << 8)
                        | (UInt64(content[12]))

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
                if let hello = try? JSONDecoder().decode(HelloPayload.self, from: bodyData) {
                    Task { @MainActor in
                        self.peerUUID = hello.peerUUID
                        self.displayName = hello.displayName
                        self.manager?.handlePeerHello(hello: hello, connection: self)
                    }
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
