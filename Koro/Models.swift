import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int = 0
    var coverImageName: String?
    var iconName: String = "folder.fill"
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

@Model
final class Entry {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var lastPosition: TimeInterval?
    var audioFileURL: URL?
    var tokens: Data?

    @Relationship(inverse: \Folder.entries)
    var folder: Folder?

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now, updatedAt: Date = .now, folder: Folder? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.folder = folder
    }
}

struct WordToken: Codable {
    let word: String
    let nsRange: NSRange
    let startTime: TimeInterval
    let endTime: TimeInterval
}
