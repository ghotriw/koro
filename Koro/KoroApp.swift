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
        // Suppress Metal JIT compiler warnings from MLX (e.g. "unused variable")
        setenv("MTL_COMPILER_FLAGS", "-w", 1)
        setenv("MTL_IGNORE_WARNINGS", "1", 1)

        // Configure MLX GPU limits to prevent iOS from killing the app due to OOM
        let defaults = UserDefaults.standard
        let memoryLimitMB = defaults.object(forKey: "mlxMemoryLimit") as? Int ?? 900
        let cacheLimitMB = defaults.object(forKey: "mlxCacheLimit") as? Int ?? 50
        
        GPU.set(cacheLimit: cacheLimitMB * 1024 * 1024)
        GPU.set(memoryLimit: memoryLimitMB * 1024 * 1024)
        
        print("🚀 MLX configured: Memory Limit = \(memoryLimitMB)MB, Cache Limit = \(cacheLimitMB)MB")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Folder.self, Entry.self, Tombstone.self])
    }
}
