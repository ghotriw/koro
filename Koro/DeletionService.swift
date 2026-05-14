import Foundation
import SwiftData

/// Central deletion utility. Always use this instead of calling modelContext.delete directly.
/// Ensures files are cleaned up and tombstones are written (when sync is active).
enum DeletionService {

    // MARK: - Public API

    static func delete(_ folder: Folder, in context: ModelContext) {
        // Write tombstones for all child entries first (cascade won't do it for us)
        for entry in folder.entries {
            writeEntryTombstone(entry, in: context)
            removeEntryFiles(entry)
        }

        // Write tombstone for the folder itself
        writeFolderTombstone(folder, in: context)

        // Clean up cover image
        if let imageName = folder.coverImageName {
            CoverImageManager.shared.deleteImage(named: imageName)
        }

        // Physical delete — cascade removes entries from SwiftData
        context.delete(folder)
    }

    static func delete(_ entry: Entry, in context: ModelContext) {
        writeEntryTombstone(entry, in: context)
        removeEntryFiles(entry)
        context.delete(entry)
    }

    // MARK: - Private helpers

    private static var hasEverPaired: Bool {
        UserDefaults.standard.bool(forKey: "koro.hasEverPaired")
    }

    private static func writeFolderTombstone(_ folder: Folder, in context: ModelContext) {
        guard hasEverPaired else { return }
        let tombstone = Tombstone(
            id: folder.id,
            entityType: "folder",
            deletedAt: .now,
            version: folder.version + 1
        )
        context.insert(tombstone)
    }

    private static func writeEntryTombstone(_ entry: Entry, in context: ModelContext) {
        guard hasEverPaired else { return }
        let tombstone = Tombstone(
            id: entry.id,
            entityType: "entry",
            deletedAt: .now,
            version: entry.version + 1
        )
        context.insert(tombstone)
    }

    private static func removeEntryFiles(_ entry: Entry) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        if let audioURL = entry.audioFileURL {
            let resolved = docs.appendingPathComponent(audioURL.lastPathComponent)
            try? fm.removeItem(at: resolved)
        }
    }
}
