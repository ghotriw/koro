import SwiftUI

struct CoverView: View {
    let title: String
    let imageName: String?
    let size: CGFloat
    let isFolder: Bool
    let iconName: String?

    init(title: String, imageName: String? = nil, size: CGFloat, isFolder: Bool, iconName: String? = nil) {
        self.title = title
        self.imageName = imageName
        self.size = size
        self.isFolder = isFolder
        self.iconName = iconName
    }

    private var uiImage: UIImage? {
        if let imageName, let url = CoverImageManager.shared.getURL(for: imageName) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }
    
    private var color: Color {
        // ... (hash calculation remains same)
        var hash: UInt32 = 0
        for byte in title.utf8 {
            hash = (hash &+ UInt32(byte)).shl(5) &- (hash &+ UInt32(byte))
        }

        let hue = Double(abs(Int(hash)) % 360) / 360.0
        return Color(hue: hue, saturation: 0.4, brightness: 0.8)
    }
    
    private var gradient: LinearGradient {
        LinearGradient(
            colors: [color, color.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var cleanedInitial: String {
        // ... (regex calculation remains same)
        let pattern = "^[0-9]+([\\.\\-\\–\\—\\)]\\s*|\\s+[\\.\\-\\–\\—\\)]?\\s*)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(location: 0, length: title.utf16.count)
            let cleaned = regex.stringByReplacingMatches(in: title, options: [], range: range, withTemplate: "")
            let initial = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1).uppercased()
            return initial.isEmpty ? title.prefix(1).uppercased() : initial
        }
        return title.prefix(1).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(gradient)

                    Text(cleanedInitial)
                        .font(.system(size: size * 0.4, weight: .bold, design: .serif))
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(radius: 2)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: iconName ?? (isFolder ? "folder.fill" : "waveform"))
                                .font(.system(size: size * 0.15))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(8)
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: size, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private extension UInt32 {
    func shl(_ bits: UInt32) -> UInt32 {
        return (self << bits) | (self >> (32 - bits))
    }
}

#Preview {
    HStack(spacing: 20) {
        CoverView(title: "Design Patterns", imageName: nil, size: 150, isFolder: true)
        CoverView(title: "SwiftUI Deep Dive", imageName: nil, size: 150, isFolder: false)
    }
    .padding()
}
