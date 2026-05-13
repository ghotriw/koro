import Foundation
import SwiftData

@Model
final class Folder {
    var name: String
    var createdAt: Date
    var sortOrder: Int = 0
    var coverImageName: String?
    var iconName: String = "folder.fill"
    @Relationship(deleteRule: .cascade)
    var entries: [Entry] = []
    
    init(name: String, createdAt: Date = .now, sortOrder: Int = 0, coverImageName: String? = nil, iconName: String = "folder.fill") {
        self.name = name
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.coverImageName = coverImageName
        self.iconName = iconName
    }
}

@Model
final class Entry {
    var title: String
    var body: String
    var createdAt: Date
    var lastPosition: TimeInterval?
    var audioFileURL: URL?
    var tokens: Data?
    var coverImageData: Data?
    
    @Relationship(inverse: \Folder.entries)
    var folder: Folder?
    
    init(title: String, body: String, createdAt: Date = .now, folder: Folder? = nil, coverImageData: Data? = nil) {
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.folder = folder
        self.coverImageData = coverImageData
    }
}

struct WordToken: Codable {
    let word: String
    let nsRange: NSRange
    let startTime: TimeInterval
    let endTime: TimeInterval
}
