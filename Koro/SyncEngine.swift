import Foundation
import MultipeerConnectivity
import SwiftData

/// Implements the diff/merge algorithm from P2P_SYNC_ARCHITECTURE.md §4.
@MainActor
enum SyncEngine {

    // MARK: - Pending resource tracking

    /// Staged incoming entries — DB is NOT mutated until `isComplete`.
    private static var pendingEntryResources: [UUID: PendingEntry] = [:]

    /// Tracks outgoing file transfers per peer.
    private static var inFlightSends: [UUID: Int] = [:]

    private static func incrementSend(for peerUUID: UUID) {
        inFlightSends[peerUUID, default: 0] += 1
    }

    private static func decrementSend(for peerUUID: UUID, manager: P2PManager) {
        inFlightSends[peerUUID, default: 0] -= 1
        checkCompletion(for: peerUUID, manager: manager)
    }

    private static func checkCompletion(for peerUUID: UUID, manager: P2PManager) {
        let receiving = pendingEntryResources.count > 0
        let sending = (inFlightSends[peerUUID] ?? 0) > 0
        if !receiving && !sending {
            syncLog("🏁 SyncEngine: All transfers complete for \(peerUUID). State -> .synced")
            manager.setPeerState(peerUUID, .synced)
        }
    }

    private struct PendingEntry {
        let record: SyncManifest.EntryRecord
        let isInsert: Bool          // true → create new Entry; false → update existing
        let needsBody: Bool
        let needsAudio: Bool

        var bodyReceived = false
        var audioReceived = false
        var tokensReceived = false
        var bodyText: String = ""
        var audioLocalURL: URL?
        var tokensData: Data?

        var isComplete: Bool {
            (!needsBody || bodyReceived) && (!needsAudio || (audioReceived && tokensReceived))
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
        syncLog("🔄 SyncEngine: Starting merge with peer \(remotePeerUUID)")
        let localFolders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let localEntries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let localTombstones = (try? context.fetch(FetchDescriptor<Tombstone>())) ?? []

        var localFolderMap = Dictionary(uniqueKeysWithValues: localFolders.map { ($0.id, $0) })
        let localEntryMap = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })
        let localTombstoneMap = Dictionary(uniqueKeysWithValues: localTombstones.map { ($0.id, $0) })

        let remoteFolderMap = Dictionary(uniqueKeysWithValues: remote.folders.map { ($0.id, $0) })
        let remoteEntryMap = Dictionary(uniqueKeysWithValues: remote.entries.map { ($0.id, $0) })
        let remoteTombstoneMap = Dictionary(uniqueKeysWithValues: remote.tombstones.map { ($0.id, $0) })

        // Cover dedup: hashes the peer already has → if our cover hash matches one of theirs, skip the push.
        let peerCoverHashes = Set(remote.folders.compactMap { $0.coverHash })
        // Cover dedup: hashes WE already have locally (any folder, any filename) → if peer's hash matches, reuse.
        let localCoverByHash: [String: String] = Dictionary(
            localFolders.compactMap { f -> (String, String)? in
                guard let h = f.coverHash, let name = f.coverImageName else { return nil }
                return (h, name)
            },
            uniquingKeysWith: { first, _ in first }
        )

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
                localFolderMap: &localFolderMap,
                peerCoverHashes: peerCoverHashes,
                localCoverByHash: localCoverByHash,
                remotePeerUUID: remotePeerUUID, manager: manager
            )
        }

        for id in allEntryIDs {
            processEntryDiff(
                id: id,
                local: localEntryMap[id], remote: remoteEntryMap[id],
                localTomb: localTombstoneMap[id], remoteTomb: remoteTombstoneMap[id],
                remotePeerID: remotePeerID, session: session, context: context,
                localFolderMap: localFolderMap,
                remotePeerUUID: remotePeerUUID, manager: manager
            )
        }

        // Tombstone sync
        for rt in remote.tombstones {
            if let lt = localTombstoneMap[rt.id] {
                if rt.version > lt.version {
                    syncLog("🪦 SyncEngine: Updating tombstone \(rt.entityType) \(rt.id) (v\(lt.version) → v\(rt.version))")
                    lt.version = rt.version
                    lt.deletedAt = rt.deletedAt
                }
            } else if pendingEntryResources[rt.id] == nil {
                // Don't import a tombstone for an id we're currently staging as a resurrection
                syncLog("🪦 SyncEngine: Importing tombstone \(rt.entityType) \(rt.id) v\(rt.version)")
                let t = Tombstone(id: rt.id, entityType: rt.entityType, deletedAt: rt.deletedAt, version: rt.version)
                context.insert(t)
            }
        }

        try? context.save()
        checkCompletion(for: remotePeerUUID, manager: manager)
    }

    // MARK: - Folder diff

    private static func processFolderDiff(
        id: UUID, local: Folder?, remote: SyncManifest.FolderRecord?,
        localTomb: Tombstone?, remoteTomb: SyncManifest.TombstoneRecord?,
        remotePeerID: MCPeerID, session: MCSession, context: ModelContext,
        localFolderMap: inout [UUID: Folder],
        peerCoverHashes: Set<String>,
        localCoverByHash: [String: String],
        remotePeerUUID: UUID, manager: P2PManager
    ) {
        switch (local, remote, localTomb, remoteTomb) {

        case let (l?, r?, _, _):
            if r.version > l.version || (r.version == l.version && r.updatedAt > l.updatedAt) {
                syncLog("📁 SyncEngine: Updating folder \(l.name)")
                applyFolderRecord(r, to: l, localCoverByHash: localCoverByHash)
            } else if l.version > r.version || (l.version == r.version && l.updatedAt > r.updatedAt) {
                pushFolder(l, remote: r, peerCoverHashes: peerCoverHashes,
                           via: session, to: remotePeerID, peerUUID: remotePeerUUID, manager: manager)
            }

        case let (l?, nil, _, rt?):
            if rt.version > l.version {
                syncLog("🗑️ SyncEngine: Deleting folder \(l.name) (remote tombstone v\(rt.version) > local v\(l.version))")
                DeletionService.delete(l, in: context)
            } else {
                pushFolder(l, remote: nil, peerCoverHashes: peerCoverHashes,
                           via: session, to: remotePeerID, peerUUID: remotePeerUUID, manager: manager)
            }

        case let (nil, r?, lt?, _):
            if r.version > lt.version {
                context.delete(lt)
                syncLog("📁 SyncEngine: Inserting new folder \(r.name)")
                insertFolder(r, context: context, localFolderMap: &localFolderMap, localCoverByHash: localCoverByHash)
            }

        case let (nil, r?, nil, _):
            syncLog("📁 SyncEngine: Inserting new folder \(r.name)")
            insertFolder(r, context: context, localFolderMap: &localFolderMap, localCoverByHash: localCoverByHash)

        case let (l?, nil, _, nil):
            pushFolder(l, remote: nil, peerCoverHashes: peerCoverHashes,
                       via: session, to: remotePeerID, peerUUID: remotePeerUUID, manager: manager)

        default:
            break
        }
    }

    private static func applyFolderRecord(_ r: SyncManifest.FolderRecord, to l: Folder, localCoverByHash: [String: String]) {
        l.name = r.name
        l.iconName = r.iconName
        l.sortOrder = r.sortOrder
        l.version = r.version
        l.observedVersion = max(r.observedVersion, r.version)
        l.updatedAt = r.updatedAt

        if let peerHash = r.coverHash {
            if l.coverHash != peerHash {
                if let existingName = localCoverByHash[peerHash] {
                    // Dedup: reuse a local file with matching hash. Plan §4 step 3.
                    duplicateCoverFile(fromName: existingName, toName: r.coverImageName)
                    l.coverImageName = r.coverImageName
                    l.coverHash = peerHash
                }
                // else: peer will push the cover via sendResource → applyCover
            }
        } else {
            // Peer dropped the cover
            if let oldName = l.coverImageName {
                CoverImageManager.shared.deleteImage(named: oldName)
            }
            l.coverImageName = nil
            l.coverHash = nil
        }
    }

    private static func insertFolder(_ r: SyncManifest.FolderRecord, context: ModelContext,
                                     localFolderMap: inout [UUID: Folder],
                                     localCoverByHash: [String: String]) {
        let f = Folder(
            id: r.id,
            name: r.name,
            createdAt: r.createdAt,
            updatedAt: r.updatedAt,
            sortOrder: r.sortOrder,
            coverImageName: nil,
            iconName: r.iconName
        )
        f.version = r.version
        f.observedVersion = max(r.observedVersion, r.version)

        // Cover dedup on insert (plan §4 step 3).
        // Only set coverImageName if the file is already present locally — otherwise wait for
        // applyCover (sendResource). Setting it pointing to a non-existent file confuses SwiftUI:
        // the view renders a placeholder, and when the file later arrives applyCover writes the
        // same filename back, which SwiftData treats as a no-op change → no re-render until next launch.
        if let peerHash = r.coverHash, let existingName = localCoverByHash[peerHash] {
            duplicateCoverFile(fromName: existingName, toName: r.coverImageName)
            f.coverImageName = r.coverImageName
            f.coverHash = peerHash
        } else {
            f.coverImageName = nil
            f.coverHash = nil
        }

        context.insert(f)
        localFolderMap[f.id] = f
    }

    private static func duplicateCoverFile(fromName: String, toName: String?) {
        guard let toName = toName, toName != fromName else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let coversDir = docs.appendingPathComponent("Covers")
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        let src = coversDir.appendingPathComponent(fromName)
        let dst = coversDir.appendingPathComponent(toName)
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
        try? fm.copyItem(at: src, to: dst)
    }

    // MARK: - Entry diff

    private static func processEntryDiff(
        id: UUID, local: Entry?, remote: SyncManifest.EntryRecord?,
        localTomb: Tombstone?, remoteTomb: SyncManifest.TombstoneRecord?,
        remotePeerID: MCPeerID, session: MCSession, context: ModelContext,
        localFolderMap: [UUID: Folder],
        remotePeerUUID: UUID, manager: P2PManager
    ) {
        switch (local, remote, localTomb, remoteTomb) {

        case let (l?, r?, _, _):
            if r.version > l.version || (r.version == l.version && r.updatedAt > l.updatedAt) {
                syncLog("📄 SyncEngine: Diff update for entry \(l.title)")
                stageOrApplyUpdate(r, existing: l, localFolderMap: localFolderMap)
            } else if l.version > r.version || (l.version == r.version && l.updatedAt > r.updatedAt) {
                pushEntry(l, remote: r, via: session, to: remotePeerID, peerUUID: remotePeerUUID, manager: manager)
            }
            mergeLastPosition(remote: r, local: l)

        case let (l?, nil, _, rt?):
            if rt.version > l.version {
                syncLog("🗑️ SyncEngine: Deleting entry \(l.title) (remote tombstone v\(rt.version) > local v\(l.version))")
                DeletionService.delete(l, in: context)
            } else {
                pushEntry(l, remote: nil, via: session, to: remotePeerID, peerUUID: remotePeerUUID, manager: manager)
            }

        case let (nil, r?, lt?, _):
            if r.version > lt.version {
                // Defer: tombstone removal & insertion happen in flushIfComplete
                stageInsert(r)
            }

        case let (nil, r?, nil, _):
            stageInsert(r)

        case let (l?, nil, _, nil):
            pushEntry(l, remote: nil, via: session, to: remotePeerID, peerUUID: remotePeerUUID, manager: manager)

        default:
            break
        }
    }

    /// Stage an update: defer metadata write until all required resources arrive.
    /// If no resources are needed, apply immediately.
    private static func stageOrApplyUpdate(_ r: SyncManifest.EntryRecord, existing l: Entry, localFolderMap: [UUID: Folder]) {
        let needsBody = (l.bodyHash != r.bodyHash)
        let needsAudio = hashesDisagree(localHash: l.audioHash, remoteHash: r.audioHash)

        if !needsBody && !needsAudio {
            applyEntryMetadata(r, to: l, localFolderMap: localFolderMap)
            return
        }
        pendingEntryResources[r.id] = PendingEntry(
            record: r,
            isInsert: false,
            needsBody: needsBody,
            needsAudio: needsAudio
        )
    }

    private static func stageInsert(_ r: SyncManifest.EntryRecord) {
        pendingEntryResources[r.id] = PendingEntry(
            record: r,
            isInsert: true,
            needsBody: true,
            needsAudio: r.audioHash != nil
        )
    }

    private static func applyEntryMetadata(_ r: SyncManifest.EntryRecord, to l: Entry, localFolderMap: [UUID: Folder]) {
        l.title = r.title
        l.sortOrder = r.sortOrder
        l.version = r.version
        l.observedVersion = max(r.observedVersion, r.version)
        l.updatedAt = r.updatedAt
        l.audioHash = r.audioHash
        l.fileSize = r.fileSize
        l.bodyHash = r.bodyHash
        l.folder = r.folderId.flatMap { localFolderMap[$0] }
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

    private static func pushFolder(_ folder: Folder, remote: SyncManifest.FolderRecord?,
                                   peerCoverHashes: Set<String>,
                                   via session: MCSession, to peerID: MCPeerID, peerUUID: UUID, manager: P2PManager) {
        guard hashesDisagree(localHash: folder.coverHash, remoteHash: remote?.coverHash) else { return }
        guard let name = folder.coverImageName, let hash = folder.coverHash else { return }
        // Plan §4 step 3: skip push if peer already has any folder with same coverHash
        if peerCoverHashes.contains(hash) { return }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let coverURL = docs.appendingPathComponent("Covers/\(name)")
        guard fm.fileExists(atPath: coverURL.path) else { return }
        let resourceName = "cover:\(folder.id.uuidString)"

        incrementSend(for: peerUUID)
        syncLog("📤 SyncEngine: Sending cover resource \(resourceName)")
        session.sendResource(at: coverURL, withName: resourceName, toPeer: peerID) { err in
            Task { @MainActor in
                if let err = err { syncLog("❌ SyncEngine: Send cover error: \(err)") }
                decrementSend(for: peerUUID, manager: manager)
            }
        }
    }

    private static func pushEntry(_ entry: Entry, remote: SyncManifest.EntryRecord?,
                                  via session: MCSession, to peerID: MCPeerID, peerUUID: UUID, manager: P2PManager) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Body — only push when peer's bodyHash doesn't match ours (plan §2: heavy data on demand)
        let bodyNeeded = (entry.bodyHash != remote?.bodyHash)
        if bodyNeeded {
            let bodyData = entry.body.data(using: .utf8) ?? Data()
            let bodyTempURL = fm.temporaryDirectory.appendingPathComponent("\(entry.id.uuidString)_body.txt")
            try? bodyData.write(to: bodyTempURL)
            let bodyName = "body:\(entry.id.uuidString)"

            incrementSend(for: peerUUID)
            syncLog("📤 SyncEngine: Sending body resource \(bodyName)")
            session.sendResource(at: bodyTempURL, withName: bodyName, toPeer: peerID) { err in
                Task { @MainActor in
                    try? fm.removeItem(at: bodyTempURL)
                    if let err = err { syncLog("❌ SyncEngine: Send body error: \(err)") }
                    decrementSend(for: peerUUID, manager: manager)
                }
            }
        }

        if hashesDisagree(localHash: entry.audioHash, remoteHash: remote?.audioHash) {
            if let audioURL = entry.audioFileURL {
                let resolvedAudio = docs.appendingPathComponent(audioURL.lastPathComponent)
                if fm.fileExists(atPath: resolvedAudio.path) {
                    incrementSend(for: peerUUID)
                    syncLog("📤 SyncEngine: Sending audio resource audio:\(entry.id.uuidString)")
                    session.sendResource(at: resolvedAudio, withName: "audio:\(entry.id.uuidString)", toPeer: peerID) { err in
                        Task { @MainActor in
                            if let err = err { syncLog("❌ SyncEngine: Send audio error: \(err)") }
                            decrementSend(for: peerUUID, manager: manager)
                        }
                    }
                }
            }

            if let tokensData = entry.tokens {
                let tokensTempURL = fm.temporaryDirectory.appendingPathComponent("\(entry.id.uuidString)_tokens.json")
                try? tokensData.write(to: tokensTempURL)
                incrementSend(for: peerUUID)
                syncLog("📤 SyncEngine: Sending tokens resource tokens:\(entry.id.uuidString)")
                session.sendResource(at: tokensTempURL, withName: "tokens:\(entry.id.uuidString)", toPeer: peerID) { err in
                    Task { @MainActor in
                        try? fm.removeItem(at: tokensTempURL)
                        if let err = err { syncLog("❌ SyncEngine: Send tokens error: \(err)") }
                        decrementSend(for: peerUUID, manager: manager)
                    }
                }
            }
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
        syncLog("📥 SyncEngine: Received resource \(type) for ID \(idStr) from \(fromPeerUUID)")

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
        guard let pending = pendingEntryResources[entryId] else { return }
        guard pending.isComplete else {
            syncLog("⏳ SyncEngine: Entry \(entryId) waiting for more resources...")
            return
        }
        syncLog("✅ SyncEngine: Entry \(entryId) resources complete, flushing to DB")
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = pending.record

        if pending.isInsert {
            // Resurrection: delete any local tombstone for this id
            let tDesc = FetchDescriptor<Tombstone>(predicate: #Predicate { $0.id == entryId })
            if let t = try? context.fetch(tDesc).first {
                context.delete(t)
            }

            let folder: Folder? = {
                guard let fid = r.folderId else { return nil }
                let fDesc = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == fid })
                return try? context.fetch(fDesc).first
            }()

            let entry = Entry(
                id: r.id,
                title: r.title,
                body: pending.bodyText,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt,
                sortOrder: r.sortOrder,
                folder: folder
            )
            entry.version = r.version
            entry.observedVersion = max(r.observedVersion, r.version)
            entry.audioHash = r.audioHash
            entry.bodyHash = r.bodyHash ?? FileHashing.sha256(string: pending.bodyText)
            entry.fileSize = r.fileSize
            entry.lastPosition = r.lastPosition
            entry.lastPositionUpdatedAt = r.lastPositionUpdatedAt

            if pending.needsAudio, let audioURL = pending.audioLocalURL {
                entry.audioFileURL = audioURL
                entry.tokens = pending.tokensData
            }
            context.insert(entry)

        } else {
            let desc = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryId })
            guard let entry = try? context.fetch(desc).first else {
                pendingEntryResources.removeValue(forKey: entryId)
                return
            }
            // Resolve folder map fresh
            let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
            let folderMap = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            applyEntryMetadata(r, to: entry, localFolderMap: folderMap)

            if pending.needsBody {
                entry.body = pending.bodyText
                entry.bodyHash = r.bodyHash ?? FileHashing.sha256(string: pending.bodyText)
            }
            if pending.needsAudio, let audioURL = pending.audioLocalURL {
                // Delete old audio file if it differs
                if let oldURL = entry.audioFileURL, oldURL.lastPathComponent != audioURL.lastPathComponent {
                    let resolved = docs.appendingPathComponent(oldURL.lastPathComponent)
                    try? fm.removeItem(at: resolved)
                }
                entry.audioFileURL = audioURL
                entry.tokens = pending.tokensData
                entry.audioHash = (try? FileHashing.sha256(url: audioURL)) ?? r.audioHash
                if let attrs = try? fm.attributesOfItem(atPath: audioURL.path) {
                    entry.fileSize = attrs[.size] as? Int64
                }
                // Stale position invalid for new audio (plan §4 step 4)
                entry.lastPosition = nil
                entry.lastPositionUpdatedAt = .now
            }
        }

        try? context.save()
        pendingEntryResources.removeValue(forKey: entryId)
        checkCompletion(for: fromPeerUUID, manager: manager)
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
        return localHash != remoteHash
    }
}
