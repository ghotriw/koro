import Foundation
import MultipeerConnectivity
import SwiftData

/// Implements the diff/merge algorithm from P2P_SYNC_ARCHITECTURE.md §4.
@MainActor
enum SyncEngine {

    // MARK: - Pending resource tracking

    /// Tracks expected resources for an entry before atomic commit.
    private static var pendingEntryResources: [UUID: PendingEntry] = [:]

    private struct PendingEntry {
        let record: SyncManifest.EntryRecord
        var bodyReceived: Bool = false
        var audioReceived: Bool = false
        var tokensReceived: Bool = false
        var bodyText: String = ""
        var audioLocalURL: URL?
        var tokensData: Data?

        // No audio means only body is needed
        var hasAudio: Bool { record.audioHash != nil }
        var isComplete: Bool {
            if hasAudio { return bodyReceived && audioReceived && tokensReceived }
            return bodyReceived
        }
    }

    // MARK: - Main merge entry point

    static func merge(
        remote: SyncManifest,
        remotePeerUUID: UUID,
        remotePeerID: MCPeerID,
        session: MCSession,
        context: ModelContext,
        manager: P2PManager
    ) {
        let localFolders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let localEntries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let localTombstones = (try? context.fetch(FetchDescriptor<Tombstone>())) ?? []

        var localFolderMap = Dictionary(uniqueKeysWithValues: localFolders.map { ($0.id, $0) })
        let localEntryMap = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })
        let localTombstoneMap = Dictionary(uniqueKeysWithValues: localTombstones.map { ($0.id, $0) })

        let remoteFolderMap = Dictionary(uniqueKeysWithValues: remote.folders.map { ($0.id, $0) })
        let remoteEntryMap = Dictionary(uniqueKeysWithValues: remote.entries.map { ($0.id, $0) })
        let remoteTombstoneMap = Dictionary(uniqueKeysWithValues: remote.tombstones.map { ($0.id, $0) })

        let allFolderIDs = Set(localFolderMap.keys)
            .union(remoteFolderMap.keys)
            .union(localTombstoneMap.filter { $0.value.entityType == "folder" }.keys)
            .union(remoteTombstoneMap.filter { $0.value.entityType == "folder" }.keys)

        let allEntryIDs = Set(localEntryMap.keys)
            .union(remoteEntryMap.keys)
            .union(localTombstoneMap.filter { $0.value.entityType == "entry" }.keys)
            .union(remoteTombstoneMap.filter { $0.value.entityType == "entry" }.keys)

        for id in allFolderIDs {
            processFolderDiff(
                id: id,
                local: localFolderMap[id], remote: remoteFolderMap[id],
                localTomb: localTombstoneMap[id], remoteTomb: remoteTombstoneMap[id],
                remotePeerID: remotePeerID, session: session, context: context,
                localFolderMap: &localFolderMap
            )
        }

        for id in allEntryIDs {
            processEntryDiff(
                id: id,
                local: localEntryMap[id], remote: remoteEntryMap[id],
                localTomb: localTombstoneMap[id], remoteTomb: remoteTombstoneMap[id],
                remotePeerID: remotePeerID, session: session, context: context,
                localFolderMap: localFolderMap
            )
        }

        // Tombstone sync
        for rt in remote.tombstones {
            if let lt = localTombstoneMap[rt.id] {
                if rt.version > lt.version {
                    lt.version = rt.version
                    lt.deletedAt = rt.deletedAt
                }
            } else {
                let t = Tombstone(id: rt.id, entityType: rt.entityType, deletedAt: rt.deletedAt, version: rt.version)
                context.insert(t)
            }
        }

        manager.setPeerState(remotePeerUUID, .synced)
        try? context.save()
    }

    // MARK: - Folder diff

    private static func processFolderDiff(
        id: UUID, local: Folder?, remote: SyncManifest.FolderRecord?,
        localTomb: Tombstone?, remoteTomb: SyncManifest.TombstoneRecord?,
        remotePeerID: MCPeerID, session: MCSession, context: ModelContext,
        localFolderMap: inout [UUID: Folder]
    ) {
        switch (local, remote, localTomb, remoteTomb) {

        case let (l?, r?, _, _):
            if r.version > l.version {
                applyFolderRecord(r, to: l)
                if hashesDisagree(localHash: l.coverHash, remoteHash: r.coverHash) {
                    // Peer will push cover proactively on their diff pass
                }
            } else if l.version > r.version {
                pushFolder(l, remote: r, via: session, to: remotePeerID)
            } else if r.updatedAt > l.updatedAt {
                applyFolderRecord(r, to: l)
            } else if l.updatedAt > r.updatedAt {
                pushFolder(l, remote: r, via: session, to: remotePeerID)
            }

        case let (l?, nil, _, rt?):
            if rt.version > l.version {
                DeletionService.delete(l, in: context)
            } else {
                pushFolder(l, remote: nil, via: session, to: remotePeerID)
            }

        case let (nil, r?, lt?, _):
            if r.version > lt.version {
                context.delete(lt)
                insertFolder(r, context: context, localFolderMap: &localFolderMap)
            }

        case let (nil, r?, nil, _):
            insertFolder(r, context: context, localFolderMap: &localFolderMap)

        case let (l?, nil, _, nil):
            pushFolder(l, remote: nil, via: session, to: remotePeerID)

        default:
            break
        }
    }

    private static func applyFolderRecord(_ r: SyncManifest.FolderRecord, to l: Folder) {
        l.name = r.name
        l.iconName = r.iconName
        l.sortOrder = r.sortOrder
        l.version = r.version
        l.observedVersion = r.version
        l.updatedAt = r.updatedAt
        if let name = r.coverImageName { l.coverImageName = name }
    }

    private static func insertFolder(_ r: SyncManifest.FolderRecord, context: ModelContext, localFolderMap: inout [UUID: Folder]) {
        let f = Folder(id: r.id, name: r.name, sortOrder: r.sortOrder, coverImageName: r.coverImageName, iconName: r.iconName)
        f.version = r.version
        f.observedVersion = r.version
        f.coverHash = r.coverHash
        context.insert(f)
        localFolderMap[f.id] = f
    }

    // MARK: - Entry diff

    private static func processEntryDiff(
        id: UUID, local: Entry?, remote: SyncManifest.EntryRecord?,
        localTomb: Tombstone?, remoteTomb: SyncManifest.TombstoneRecord?,
        remotePeerID: MCPeerID, session: MCSession, context: ModelContext,
        localFolderMap: [UUID: Folder]
    ) {
        switch (local, remote, localTomb, remoteTomb) {

        case let (l?, r?, _, _):
            if r.version > l.version {
                applyEntryMetadata(r, to: l, localFolderMap: localFolderMap)
                if hashesDisagree(localHash: l.audioHash, remoteHash: r.audioHash) {
                    pendingEntryResources[id] = PendingEntry(record: r)
                }
            } else if l.version > r.version {
                pushEntry(l, remote: r, via: session, to: remotePeerID)
            } else if r.updatedAt > l.updatedAt {
                applyEntryMetadata(r, to: l, localFolderMap: localFolderMap)
                if hashesDisagree(localHash: l.audioHash, remoteHash: r.audioHash) {
                    pendingEntryResources[id] = PendingEntry(record: r)
                }
            } else if l.updatedAt > r.updatedAt {
                pushEntry(l, remote: r, via: session, to: remotePeerID)
            }
            mergeLastPosition(remote: r, local: l)

        case let (l?, nil, _, rt?):
            if rt.version > l.version {
                DeletionService.delete(l, in: context)
            } else {
                pushEntry(l, remote: nil, via: session, to: remotePeerID)
            }

        case let (nil, r?, lt?, _):
            if r.version > lt.version {
                context.delete(lt)
                let folder = r.folderId.flatMap { localFolderMap[$0] }
                insertEntry(r, folder: folder, context: context)
                pendingEntryResources[id] = PendingEntry(record: r)
            }

        case let (nil, r?, nil, _):
            let folder = r.folderId.flatMap { localFolderMap[$0] }
            insertEntry(r, folder: folder, context: context)
            pendingEntryResources[id] = PendingEntry(record: r)

        case let (l?, nil, _, nil):
            pushEntry(l, remote: nil, via: session, to: remotePeerID)

        default:
            break
        }
    }

    private static func applyEntryMetadata(_ r: SyncManifest.EntryRecord, to l: Entry, localFolderMap: [UUID: Folder]) {
        l.title = r.title
        l.sortOrder = r.sortOrder
        l.version = r.version
        l.observedVersion = r.version
        l.updatedAt = r.updatedAt
        l.audioHash = r.audioHash
        l.fileSize = r.fileSize
        l.folder = r.folderId.flatMap { localFolderMap[$0] }
    }

    private static func insertEntry(_ r: SyncManifest.EntryRecord, folder: Folder?, context: ModelContext) {
        let e = Entry(id: r.id, title: r.title, body: "", sortOrder: r.sortOrder, folder: folder)
        e.version = r.version
        e.observedVersion = r.version
        e.updatedAt = r.updatedAt
        e.audioHash = r.audioHash
        e.fileSize = r.fileSize
        context.insert(e)
    }

    private static func mergeLastPosition(remote: SyncManifest.EntryRecord, local: Entry) {
        guard let remoteLP = remote.lastPosition,
              let remoteLPAt = remote.lastPositionUpdatedAt else { return }
        let localLPAt = local.lastPositionUpdatedAt ?? .distantPast
        if remoteLPAt > localLPAt {
            local.lastPosition = remoteLP
            local.lastPositionUpdatedAt = remoteLPAt
        }
    }

    // MARK: - Push helpers (what WE send TO peer)

    private static func pushFolder(_ folder: Folder, remote: SyncManifest.FolderRecord?, via session: MCSession, to peerID: MCPeerID) {
        guard hashesDisagree(localHash: folder.coverHash, remoteHash: remote?.coverHash) else { return }
        guard let name = folder.coverImageName else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let coverURL = docs.appendingPathComponent("Covers/\(name)")
        guard fm.fileExists(atPath: coverURL.path) else { return }
        let resourceName = "cover:\(folder.id.uuidString)"
        session.sendResource(at: coverURL, withName: resourceName, toPeer: peerID) { _ in }
    }

    private static func pushEntry(_ entry: Entry, remote: SyncManifest.EntryRecord?, via session: MCSession, to peerID: MCPeerID) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Body text — always send for content sync
        let bodyData = entry.body.data(using: .utf8) ?? Data()
        let bodyTempURL = fm.temporaryDirectory.appendingPathComponent("\(entry.id.uuidString)_body.txt")
        try? bodyData.write(to: bodyTempURL)
        let bodyName = "body:\(entry.id.uuidString)"
        session.sendResource(at: bodyTempURL, withName: bodyName, toPeer: peerID) { _ in
            try? fm.removeItem(at: bodyTempURL)
        }

        if hashesDisagree(localHash: entry.audioHash, remoteHash: remote?.audioHash) {
            if let audioURL = entry.audioFileURL {
                let resolvedAudio = docs.appendingPathComponent(audioURL.lastPathComponent)
                if fm.fileExists(atPath: resolvedAudio.path) {
                    session.sendResource(at: resolvedAudio, withName: "audio:\(entry.id.uuidString)", toPeer: peerID) { _ in }
                }
            }

            if let tokensData = entry.tokens {
                let tokensTempURL = fm.temporaryDirectory.appendingPathComponent("\(entry.id.uuidString)_tokens.json")
                try? tokensData.write(to: tokensTempURL)
                session.sendResource(at: tokensTempURL, withName: "tokens:\(entry.id.uuidString)", toPeer: peerID) { _ in
                    try? fm.removeItem(at: tokensTempURL)
                }
            }
        }
    }

    // MARK: - Tombstone signal

    static func handleTombstoneSignal(_ record: SyncManifest.TombstoneRecord, context: ModelContext) {
        let id = record.id
        if record.entityType == "folder" {
            let desc = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })
            if let folder = try? context.fetch(desc).first {
                if record.version > folder.version {
                    DeletionService.delete(folder, in: context)
                    try? context.save()
                }
            }
        } else {
            let desc = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
            if let entry = try? context.fetch(desc).first {
                if record.version > entry.version {
                    DeletionService.delete(entry, in: context)
                    try? context.save()
                }
            }
        }
    }

    private static func sendTombstoneMsg(id: UUID, entityType: String, version: Int64, via session: MCSession, to peerID: MCPeerID) {
        let record = SyncManifest.TombstoneRecord(id: id, entityType: entityType, version: version, deletedAt: .now)
        if let data = try? JSONEncoder().encode(WireMessage.tombstone(record)) {
            try? session.send(data, toPeers: [peerID], with: .reliable)
        }
    }

    // MARK: - Receive resources

    static func handleReceivedResource(
        name: String,
        at tempURL: URL,
        fromPeerUUID: UUID,
        context: ModelContext,
        manager: P2PManager
    ) {
        let fm = FileManager.default
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let type = parts[0]
        let idStr = parts[1]

        switch type {
        case "body":
            guard let entryId = UUID(uuidString: idStr) else { return }
            let text = (try? String(contentsOf: tempURL, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: tempURL)
            pendingEntryResources[entryId]?.bodyReceived = true
            pendingEntryResources[entryId]?.bodyText = text
            flushIfComplete(entryId: entryId, context: context, manager: manager, fromPeerUUID: fromPeerUUID)

        case "audio":
            guard let entryId = UUID(uuidString: idStr) else { return }
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destURL = docs.appendingPathComponent("\(entryId.uuidString).m4a")
            try? fm.removeItem(at: destURL)
            try? fm.moveItem(at: tempURL, to: destURL)
            pendingEntryResources[entryId]?.audioReceived = true
            pendingEntryResources[entryId]?.audioLocalURL = destURL
            flushIfComplete(entryId: entryId, context: context, manager: manager, fromPeerUUID: fromPeerUUID)

        case "tokens":
            guard let entryId = UUID(uuidString: idStr) else { return }
            let tokensData = (try? Data(contentsOf: tempURL)) ?? Data()
            try? fm.removeItem(at: tempURL)
            pendingEntryResources[entryId]?.tokensReceived = true
            pendingEntryResources[entryId]?.tokensData = tokensData
            flushIfComplete(entryId: entryId, context: context, manager: manager, fromPeerUUID: fromPeerUUID)

        case "cover":
            guard let folderId = UUID(uuidString: idStr) else { return }
            applyCover(folderId: folderId, tempURL: tempURL, context: context)

        default:
            try? fm.removeItem(at: tempURL)
        }
    }

    // MARK: - Atomic apply for entries

    private static func flushIfComplete(entryId: UUID, context: ModelContext, manager: P2PManager, fromPeerUUID: UUID) {
        guard let pending = pendingEntryResources[entryId], pending.isComplete else { return }
        let fm = FileManager.default

        let desc = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryId })
        guard let entry = try? context.fetch(desc).first else {
            pendingEntryResources.removeValue(forKey: entryId)
            return
        }

        entry.body = pending.bodyText

        if pending.hasAudio, let audioURL = pending.audioLocalURL {
            entry.audioFileURL = audioURL
            entry.tokens = pending.tokensData
            entry.audioHash = (try? FileHashing.sha256(url: audioURL))
            if let attrs = try? fm.attributesOfItem(atPath: audioURL.path) {
                entry.fileSize = attrs[.size] as? Int64
            }
            // Stale position invalid for new audio
            entry.lastPosition = nil
            entry.lastPositionUpdatedAt = .now
        }

        try? context.save()
        pendingEntryResources.removeValue(forKey: entryId)
        manager.setPeerState(fromPeerUUID, .synced)
    }

    private static func applyCover(folderId: UUID, tempURL: URL, context: ModelContext) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let coversDir = docs.appendingPathComponent("Covers")
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)

        let desc = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderId })
        guard let folder = try? context.fetch(desc).first else {
            try? fm.removeItem(at: tempURL)
            return
        }

        let fileName = folder.coverImageName ?? "\(UUID().uuidString).jpg"
        let destURL = coversDir.appendingPathComponent(fileName)
        try? fm.removeItem(at: destURL)
        try? fm.moveItem(at: tempURL, to: destURL)
        folder.coverImageName = fileName
        folder.coverHash = (try? FileHashing.sha256(url: destURL))
        try? context.save()
    }

    // MARK: - Helpers

    private static func hashesDisagree(localHash: String?, remoteHash: String?) -> Bool {
        guard let r = remoteHash else { return false }
        guard let l = localHash else { return true }
        return l != r
    }
}

// MARK: - On-wire message envelope (beyond HelloPayload which is handled in P2PManager)

enum WireMessage: Codable {
    case tombstone(SyncManifest.TombstoneRecord)

    enum CodingKeys: String, CodingKey { case type, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "tombstone":
            self = .tombstone(try c.decode(SyncManifest.TombstoneRecord.self, forKey: .payload))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tombstone(let r):
            try c.encode("tombstone", forKey: .type)
            try c.encode(r, forKey: .payload)
        }
    }
}
