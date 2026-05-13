import UIKit

struct CoverImageManager {
    static let shared = CoverImageManager()
    
    private let coversDirectoryName = "Covers"
    
    private var coversDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(coversDirectoryName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
    
    func saveImage(_ image: UIImage) -> String? {
        // 1. Square crop and resize to 600x600
        guard let squareImage = prepareImage(image, size: CGSize(width: 600, height: 600)) else { return nil }
        
        // 2. Convert to JPEG data
        guard let data = squareImage.jpegData(compressionQuality: 0.7) else { return nil }
        
        // 3. Save to disk with unique name
        let fileName = "\(UUID().uuidString).jpg"
        let fileURL = coversDirectoryURL.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL)
            return fileName
        } catch {
            print("Failed to save cover image: \(error)")
            return nil
        }
    }
    
    func deleteImage(named name: String?) {
        guard let name = name else { return }
        let fileURL = coversDirectoryURL.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func getURL(for name: String?) -> URL? {
        guard let name = name else { return nil }
        let fileURL = coversDirectoryURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
    
    private func prepareImage(_ image: UIImage, size: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let aspectWidth = size.width / image.size.width
            let aspectHeight = size.height / image.size.height
            let aspectRatio = max(aspectWidth, aspectHeight)
            
            let drawWidth = image.size.width * aspectRatio
            let drawHeight = image.size.height * aspectRatio
            let drawX = (size.width - drawWidth) / 2
            let drawY = (size.height - drawHeight) / 2
            
            image.draw(in: CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight))
        }
    }
}
