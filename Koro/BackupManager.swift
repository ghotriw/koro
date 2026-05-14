import Foundation
import SwiftData
import ZIPFoundation
import UniformTypeIdentifiers
import UIKit

extension UTType {
    static var korobackup: UTType {
        UTType(exportedAs: "com.ghotriw.koro.backup", conformingTo: .zip)
    }
}

@MainActor
class BackupManager {
    static let shared = BackupManager()
    
    private init() {}
    
    func createBackup(modelContext: ModelContext) throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let audioDir = tempDir.appendingPathComponent("audio")
        let coversDir = tempDir.appendingPathComponent("covers")
        let textsDir = tempDir.appendingPathComponent("texts")
        let tokensDir = tempDir.appendingPathComponent("tokens")
        
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: textsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tokensDir, withIntermediateDirectories: true)
        
        let folderDescriptor = FetchDescriptor<Folder>()
        let folders = try modelContext.fetch(folderDescriptor)
        
        let entryDescriptor = FetchDescriptor<Entry>()
        let entries = try modelContext.fetch(entryDescriptor)
        
        var manifestItems: [[String: Any]] = []
        
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        for folder in folders {
            var item: [String: Any] = [
                "type": "folder",
                "id": folder.id.uuidString,
                "name": folder.name,
                "createdAt": folder.createdAt.timeIntervalSince1970,
                "updatedAt": folder.updatedAt.timeIntervalSince1970,
                "sortOrder": folder.sortOrder,
                "iconName": folder.iconName
            ]
            
            if let coverName = folder.coverImageName {
                if let coverURL = CoverImageManager.shared.getURL(for: coverName), fm.fileExists(atPath: coverURL.path) {
                    let ext = coverURL.pathExtension
                    let newName = "\(folder.id.uuidString).\(ext)"
                    let dest = coversDir.appendingPathComponent(newName)
                    try? fm.copyItem(at: coverURL, to: dest)
                    item["coverImageName"] = newName
                }
            }
            
            manifestItems.append(item)
        }
        
        for entry in entries {
            var item: [String: Any] = [
                "type": "entry",
                "id": entry.id.uuidString,
                "title": entry.title,
                "createdAt": entry.createdAt.timeIntervalSince1970,
                "updatedAt": entry.updatedAt.timeIntervalSince1970,
                "folderId": entry.folder?.id.uuidString ?? ""
            ]
            if let lastPos = entry.lastPosition {
                item["lastPosition"] = lastPos
            }
            
            let textName = "\(entry.id.uuidString).txt"
            let textURL = textsDir.appendingPathComponent(textName)
            try? entry.body.write(to: textURL, atomically: true, encoding: .utf8)
            item["text_filename"] = textName
            
            if let tokens = entry.tokens {
                let tokenName = "\(entry.id.uuidString)_tokens.json"
                let tokenURL = tokensDir.appendingPathComponent(tokenName)
                try? tokens.write(to: tokenURL)
                item["tokens_filename"] = tokenName
            }
            
            if let audioURL = entry.audioFileURL {
                let currentAudioURL = documentsURL.appendingPathComponent(audioURL.lastPathComponent)
                if fm.fileExists(atPath: currentAudioURL.path) {
                    let ext = currentAudioURL.pathExtension
                    let newName = "\(entry.id.uuidString).\(ext)"
                    let dest = audioDir.appendingPathComponent(newName)
                    try? fm.copyItem(at: currentAudioURL, to: dest)
                    item["audio_filename"] = newName
                }
            }
            
            manifestItems.append(item)
        }
        
        let manifest: [String: Any] = [
            "version": 1,
            "items": manifestItems
        ]
        
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let dateString = formatter.string(from: Date())
        let finalZipURL = fm.temporaryDirectory.appendingPathComponent("KoroBackup_\(dateString).korobackup")
        
        if fm.fileExists(atPath: finalZipURL.path) {
            try fm.removeItem(at: finalZipURL)
        }
        
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var resultingURL: URL?
        
        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &coordinatorError) { zipURL in
            do {
                try fm.copyItem(at: zipURL, to: finalZipURL)
                resultingURL = finalZipURL
            } catch {
                print("Failed to copy zip: \(error)")
            }
        }
        
        if let error = coordinatorError { throw error }
        guard let finalResult = resultingURL else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create archive"])
        }
        
        return finalResult
    }
    
    func restoreBackup(from archiveURL: URL, modelContext: ModelContext) async throws {
        guard archiveURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        }
        defer { archiveURL.stopAccessingSecurityScopedResource() }
        
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        try fm.unzipItem(at: archiveURL, to: tempDir)
        
        var contentDir = tempDir
        let items = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        if items.count == 1, items[0].hasDirectoryPath {
            contentDir = items[0]
        }
        
        let manifestURL = contentDir.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw NSError(domain: "Backup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Manifest not found in archive"])
        }
        
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        guard let manifestItems = manifest?["items"] as? [[String: Any]] else {
            throw NSError(domain: "Backup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest format"])
        }
        
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let folderDescriptor = FetchDescriptor<Folder>()
        let existingFolders = try modelContext.fetch(folderDescriptor)
        var folderMap = Dictionary(uniqueKeysWithValues: existingFolders.map { ($0.id, $0) })
        
        let entryDescriptor = FetchDescriptor<Entry>()
        let existingEntries = try modelContext.fetch(entryDescriptor)
        var entryMap = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
        
        // 1. Process Folders
        for item in manifestItems where item["type"] as? String == "folder" {
            guard let idString = item["id"] as? String, let id = UUID(uuidString: idString),
                  let name = item["name"] as? String,
                  let updatedAtTime = item["updatedAt"] as? TimeInterval else { continue }
            
            let updatedAt = Date(timeIntervalSince1970: updatedAtTime)
            let createdAt = Date(timeIntervalSince1970: item["createdAt"] as? TimeInterval ?? updatedAtTime)
            let sortOrder = item["sortOrder"] as? Int ?? 0
            let iconName = item["iconName"] as? String ?? "folder.fill"
            let coverImageName = item["coverImageName"] as? String
            
            let applyCover: (Folder, String?) -> Void = { folder, cName in
                if let oldName = folder.coverImageName, oldName != cName {
                    CoverImageManager.shared.deleteImage(named: oldName)
                }
                if let cName {
                    let coverURL = contentDir.appendingPathComponent("covers").appendingPathComponent(cName)
                    if fm.fileExists(atPath: coverURL.path), let uiImage = UIImage(contentsOfFile: coverURL.path) {
                        folder.coverImageName = CoverImageManager.shared.saveImage(uiImage)
                    } else {
                        folder.coverImageName = nil
                    }
                } else {
                    folder.coverImageName = nil
                }
            }
            
            if let existing = folderMap[id] {
                if updatedAt > existing.updatedAt {
                    existing.name = name
                    existing.updatedAt = updatedAt
                    existing.sortOrder = sortOrder
                    existing.iconName = iconName
                    applyCover(existing, coverImageName)
                }
            } else {
                let newFolder = Folder(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt, sortOrder: sortOrder, iconName: iconName)
                applyCover(newFolder, coverImageName)
                modelContext.insert(newFolder)
                folderMap[id] = newFolder
            }
        }
        
        // 2. Process Entries
        for item in manifestItems where item["type"] as? String == "entry" {
            guard let idString = item["id"] as? String, let id = UUID(uuidString: idString),
                  let title = item["title"] as? String,
                  let updatedAtTime = item["updatedAt"] as? TimeInterval,
                  let textFileName = item["text_filename"] as? String else { continue }
            
            let textURL = contentDir.appendingPathComponent("texts").appendingPathComponent(textFileName)
            guard let body = try? String(contentsOf: textURL, encoding: .utf8) else { continue }
            
            let updatedAt = Date(timeIntervalSince1970: updatedAtTime)
            let createdAt = Date(timeIntervalSince1970: item["createdAt"] as? TimeInterval ?? updatedAtTime)
            let folderIdString = item["folderId"] as? String ?? ""
            let folderId = UUID(uuidString: folderIdString)
            let lastPosition = item["lastPosition"] as? TimeInterval
            
            let targetFolder = folderId.flatMap { folderMap[$0] }
            
            let applyAssets: (Entry) -> Void = { entry in
                if let tokensName = item["tokens_filename"] as? String {
                    let tokensURL = contentDir.appendingPathComponent("tokens").appendingPathComponent(tokensName)
                    entry.tokens = try? Data(contentsOf: tokensURL)
                }
                
                if let audioName = item["audio_filename"] as? String {
                    let audioURL = contentDir.appendingPathComponent("audio").appendingPathComponent(audioName)
                    if fm.fileExists(atPath: audioURL.path) {
                        let uniqueName = "\(UUID().uuidString).\(audioURL.pathExtension)"
                        let destURL = documentsURL.appendingPathComponent(uniqueName)
                        try? fm.copyItem(at: audioURL, to: destURL)
                        
                        // Clean old audio if needed
                        if let oldAudio = entry.audioFileURL {
                            let oldDest = documentsURL.appendingPathComponent(oldAudio.lastPathComponent)
                            try? fm.removeItem(at: oldDest)
                        }
                        
                        entry.audioFileURL = destURL
                    }
                }
            }
            
            if let existing = entryMap[id] {
                if updatedAt > existing.updatedAt {
                    existing.title = title
                    existing.body = body
                    existing.updatedAt = updatedAt
                    existing.folder = targetFolder
                    existing.lastPosition = lastPosition
                    applyAssets(existing)
                }
            } else {
                let newEntry = Entry(id: id, title: title, body: body, createdAt: createdAt, updatedAt: updatedAt, folder: targetFolder)
                newEntry.lastPosition = lastPosition
                applyAssets(newEntry)
                modelContext.insert(newEntry)
                entryMap[id] = newEntry
            }
        }
        
        try modelContext.save()
    }
}