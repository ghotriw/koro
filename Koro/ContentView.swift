//
//  ContentView.swift
//  Koro
//
//  Created by Andrii Honcharov on 12.05.2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [Entry]
    @Query private var folders: [Folder]

    var body: some View {
        LibraryView()
            .task {
                await startupMaintenance()
            }
    }

    @MainActor
    private func startupMaintenance() async {
        // Backfill missing audio/cover hashes for sync
        FileHashing.backfillHashes(entries: entries, folders: folders)

        // Vacuum tombstones older than 30 days
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<Tombstone>(
            predicate: #Predicate { $0.deletedAt < cutoff }
        )
        if let stale = try? modelContext.fetch(descriptor) {
            stale.forEach { modelContext.delete($0) }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Folder.self, Entry.self, Tombstone.self], inMemory: true)
}
