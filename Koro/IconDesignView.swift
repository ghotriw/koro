import SwiftUI

struct KoroIconView: View {
    var body: some View {
        ZStack {
            // Background: Sakura/Heart Gradient
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.46, blue: 0.55), Color(red: 1.0, green: 0.49, blue: 0.70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 0) {
                Spacer()
                
                HStack(alignment: .bottom, spacing: 12) {
                    // Left Book (Tilted)
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .overlay(Rectangle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .frame(width: 60, height: 160)
                        .cornerRadius(8)
                        .rotationEffect(.degrees(-10), anchor: .bottomTrailing)
                        .offset(x: 10)
                    
                    // Center Book (Main)
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                            .cornerRadius(8)
                        
                        Image(systemName: "heart.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.8))
                            .offset(y: -30)
                    }
                    .frame(width: 75, height: 200)
                    
                    // Right Book
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .frame(width: 55, height: 140)
                        .cornerRadius(8)
                }
                
                // Shelf line
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 280, height: 8)
                    .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
                
                Spacer().frame(height: 80)
            }
        }
        .frame(width: 512, height: 512)
        .clipShape(RoundedRectangle(cornerRadius: 114, style: .continuous))
    }
}

#Preview {
    KoroIconView()
        .scaleEffect(0.5) 
}
