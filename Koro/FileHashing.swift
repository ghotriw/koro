import Foundation
import CryptoKit

enum FileHashing {
    /// SHA-256 of a file, streamed in 1 MB chunks. Safe for large files. Nonisolated — pure I/O.
    /// SHA-256 of a UTF-8 string. Cheap; safe on main actor for typical body sizes.
    nonisolated static func sha256(string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(url: URL) throws -> String {
        let bufferSize = 1024 * 1024
        let stream = InputStream(url: url)!
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            hasher.update(data: Data(bytes: buffer, count: bytesRead))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fills in missing `audioHash`/`fileSize` on entries and `coverHash` on folders.
    /// Snapshots Sendable values on the main actor, then hashes in a background task.
    @MainActor
    static func backfillHashes(entries: [Entry], folders: [Folder]) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let coversDir = docs.appendingPathComponent("Covers")

        // Snapshot only the Sendable data we need; keep ObjectIdentifier to match back
        struct EntrySnapshot {
            let objectID: ObjectIdentifier
            let resolvedURL: URL
        }
        struct FolderSnapshot {
            let objectID: ObjectIdentifier
            let coverURL: URL
        }

        // Body hash is cheap — fill in synchronously here on main actor
        for e in entries where e.bodyHash == nil {
            e.bodyHash = FileHashing.sha256(string: e.body)
        }

        let entrySnapshots: [EntrySnapshot] = entries.compactMap { e in
            guard e.audioHash == nil, let url = e.audioFileURL else { return nil }
            let resolved = docs.appendingPathComponent(url.lastPathComponent)
            guard fm.fileExists(atPath: resolved.path) else { return nil }
            return EntrySnapshot(objectID: ObjectIdentifier(e), resolvedURL: resolved)
        }

        let folderSnapshots: [FolderSnapshot] = folders.compactMap { f in
            guard f.coverHash == nil, let name = f.coverImageName else { return nil }
            let coverURL = coversDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: coverURL.path) else { return nil }
            return FolderSnapshot(objectID: ObjectIdentifier(f), coverURL: coverURL)
        }

        // Build lookup maps before leaving main actor
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { (ObjectIdentifier($0), $0) })
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { (ObjectIdentifier($0), $0) })

        Task.detached(priority: .background) {
            var entryResults: [(ObjectIdentifier, String, Int64)] = []
            for snap in entrySnapshots {
                guard let hash = try? FileHashing.sha256(url: snap.resolvedURL) else { continue }
                let size = (try? fm.attributesOfItem(atPath: snap.resolvedURL.path)[.size] as? Int64) ?? 0
                entryResults.append((snap.objectID, hash, size))
            }

            var folderResults: [(ObjectIdentifier, String)] = []
            for snap in folderSnapshots {
                guard let hash = try? FileHashing.sha256(url: snap.coverURL) else { continue }
                folderResults.append((snap.objectID, hash))
            }

            let finalEntryResults = entryResults
            let finalFolderResults = folderResults
            await MainActor.run {
                for (oid, hash, size) in finalEntryResults {
                    entryByID[oid]?.audioHash = hash
                    entryByID[oid]?.fileSize = size
                }
                for (oid, hash) in finalFolderResults {
                    folderByID[oid]?.coverHash = hash
                }
            }
        }
    }
}
