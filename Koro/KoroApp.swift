//
//  KoroApp.swift
//  Koro
//
//  Created by Andrii Honcharov on 12.05.2026.
//

import SwiftUI
import SwiftData
import MLX

@main
struct KoroApp: App {
    init() {
        // Configure MLX GPU limits to prevent iOS from killing the app due to OOM
        GPU.set(cacheLimit: 50 * 1024 * 1024)   // 50 MB
        GPU.set(memoryLimit: 900 * 1024 * 1024) // 900 MB
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Folder.self, Entry.self])
    }
}
