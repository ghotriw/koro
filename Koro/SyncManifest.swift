import Foundation
import SwiftData

// MARK: - SyncManifest (on-wire, not SAF/backup format)

struct SyncManifest: Codable {
    var folders: [FolderRecord]
    var entries: [EntryRecord]
    var tombstones: [TombstoneRecord]

    struct FolderRecord: Codable {
        let id: UUID
        let name: String
        let version: Int64
        let updatedAt: Date
        let iconName: String
        let coverImageName: String?
        let coverHash: String?
        let sortOrder: Int
    }

    struct EntryRecord: Codable {
        let id: UUID
        let folderId: UUID?
        let title: String
        let version: Int64
        let updatedAt: Date
        let sortOrder: Int
        let fileSize: Int64?
        let audioHash: String?
        let lastPosition: TimeInterval?
        let lastPositionUpdatedAt: Date?
    }

    struct TombstoneRecord: Codable {
        let id: UUID
        let entityType: String
        let version: Int64
        let deletedAt: Date
    }

    // MARK: - Build from local SwiftData context

    static func build(from context: ModelContext) -> SyncManifest? {
        let folderDesc = FetchDescriptor<Folder>()
        let entryDesc = FetchDescriptor<Entry>()
        let tombstoneDesc = FetchDescriptor<Tombstone>()

        guard let folders = try? context.fetch(folderDesc),
              let entries = try? context.fetch(entryDesc),
              let tombstones = try? context.fetch(tombstoneDesc) else { return nil }

        let folderRecords = folders.map { f in
            FolderRecord(
                id: f.id,
                name: f.name,
                version: f.version,
                updatedAt: f.updatedAt,
                iconName: f.iconName,
                coverImageName: f.coverImageName,
                coverHash: f.coverHash,
                sortOrder: f.sortOrder
            )
        }

        let entryRecords = entries.map { e in
            EntryRecord(
                id: e.id,
                folderId: e.folder?.id,
                title: e.title,
                version: e.version,
                updatedAt: e.updatedAt,
                sortOrder: e.sortOrder,
                fileSize: e.fileSize,
                audioHash: e.audioHash,
                lastPosition: e.lastPosition,
                lastPositionUpdatedAt: e.lastPositionUpdatedAt
            )
        }

        let tombstoneRecords = tombstones.map { t in
            TombstoneRecord(id: t.id, entityType: t.entityType, version: t.version, deletedAt: t.deletedAt)
        }

        return SyncManifest(folders: folderRecords, entries: entryRecords, tombstones: tombstoneRecords)
    }
}
