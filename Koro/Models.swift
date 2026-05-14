import Foundation
import SwiftData

// MARK: - Versionable protocol

protocol Versionable: AnyObject {
    var version: Int64 { get set }
    var observedVersion: Int64 { get set }
    var updatedAt: Date { get set }
}

extension Versionable {
    func markAsUpdated() {
        version = max(version, observedVersion) + 1
        updatedAt = .now
    }
}

// MARK: - Folder

@Model
final class Folder: Versionable {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int = 0
    var coverImageName: String?
    var iconName: String = "folder.fill"

    // Sync fields
    var version: Int64 = 0
    var observedVersion: Int64 = 0
    var coverHash: String?

    @Relationship(deleteRule: .cascade)
    var entries: [Entry] = []

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now, sortOrder: Int = 0, coverImageName: String? = nil, iconName: String = "folder.fill") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.coverImageName = coverImageName
        self.iconName = iconName
    }
}

// MARK: - Entry

@Model
final class Entry: Versionable {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int = 0
    var lastPosition: TimeInterval?
    var audioFileURL: URL?
    var tokens: Data?

    // Sync fields
    var version: Int64 = 0
    var observedVersion: Int64 = 0
    var audioHash: String?
    var fileSize: Int64?
    var lastPositionUpdatedAt: Date?

    @Relationship(inverse: \Folder.entries)
    var folder: Folder?

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now, updatedAt: Date = .now, sortOrder: Int = 0, folder: Folder? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.folder = folder
    }
}

// MARK: - Tombstone

@Model
final class Tombstone {
    @Attribute(.unique) var id: UUID
    var entityType: String   // "folder" | "entry"
    var deletedAt: Date
    var version: Int64

    init(id: UUID, entityType: String, deletedAt: Date = .now, version: Int64) {
        self.id = id
        self.entityType = entityType
        self.deletedAt = deletedAt
        self.version = version
    }
}

// MARK: - WordToken

struct WordToken: Codable {
    let word: String
    let nsRange: NSRange
    let startTime: TimeInterval
    let endTime: TimeInterval
}
