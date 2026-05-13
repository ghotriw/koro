//
//  ContentView.swift
//  Koro
//
//  Created by Andrii Honcharov on 12.05.2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        LibraryView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Folder.self, Entry.self], inMemory: true)
}
