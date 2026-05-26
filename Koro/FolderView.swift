import SwiftUI
import SwiftData
import ZIPFoundation
import UniformTypeIdentifiers

struct FolderView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: Folder
    
    @AppStorage("entryDisplayMode") private var displayMode: DisplayMode = .grid
    
    @State private var showingAddEntrySheet = false
    @State private var entryToEdit: Entry?
    @State private var entryToOpen: Entry?
    @State private var entryToDelete: Entry?
    @State private var showingDeleteConfirmation = false
    
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var isImporting = false

    var sortedEntries: [Entry] {
        folder.entries.sorted(by: { $0.sortOrder < $1.sortOrder })
    }

    let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)
    ]

    var body: some View {
        Group {
            if displayMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .navigationTitle(folder.name)
        .navigationDestination(item: $entryToOpen) { entry in
            ReaderView(entry: entry)
        }
        .alert("Delete Entry", isPresented: $showingDeleteConfirmation, presenting: entryToDelete) { entry in
            Button("Delete", role: .destructive) {
                deleteEntry(entry)
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: { entry in
            Text("Are you sure you want to delete '\(entry.title)'? This action cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button(action: { showingImporter = true }) {
                        if isImporting {
                            ProgressView()
                        } else {
                            Label("Import ZIP", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isImporting)

                    Button(action: { showingAddEntrySheet = true }) {
                        Label("Add Entry", systemImage: "plus")
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                importZip(from: selectedURL)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            if let error = importError {
                Text(error)
            }
        }
        .sheet(isPresented: $showingAddEntrySheet) {
            NavigationStack {
                EntryEditView(folder: folder) { newEntry in
                    entryToOpen = newEntry
                }
            }
        }
        .sheet(item: $entryToEdit) { entry in
            NavigationStack {
                EntryEditView(entry: entry)
            }
        }
        .overlay {
            if folder.entries.isEmpty {
                ContentUnavailableView("No Entries", systemImage: "doc.badge.plus", description: Text("Tap the + button to create a new entry."))
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 25) {
                ForEach(sortedEntries) { entry in
                    NavigationLink {
                        ReaderView(entry: entry)
                    } label: {
                        CoverView(
                            title: entry.title,
                            size: 160,
                            isFolder: false
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = "\(entry.title)\n\n\(entry.body)"
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }

                        Button {
                            entryToEdit = entry
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        
                        Button(role: .destructive) {
                            entryToDelete = entry
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var listView: some View {
        List {
            ForEach(sortedEntries) { entry in
                NavigationLink {
                    ReaderView(entry: entry)
                } label: {
                    VStack(alignment: .leading) {
                        Text(entry.title)
                            .font(.headline)
                        Text(entry.createdAt, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        entryToDelete = entry
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    
                    Button {
                        entryToEdit = entry
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)

                    Button {
                        UIPasteboard.general.string = "\(entry.title)\n\n\(entry.body)"
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
            }
            .onMove(perform: moveEntries)
        }
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        var revisedEntries = sortedEntries
        revisedEntries.move(fromOffsets: source, toOffset: destination)

        for index in 0..<revisedEntries.count {
            revisedEntries[index].sortOrder = index
            revisedEntries[index].markAsUpdated()
        }

        try? modelContext.save()
    }

    private func importZip(from url: URL) {
        isImporting = true
        
        Task {
            do {
                // 1. Gain access to the file
                guard url.startAccessingSecurityScopedResource() else {
                    throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                let fm = FileManager.default
                let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempDir) }
                
                // 2. Unzip
                try fm.unzipItem(at: url, to: tempDir)
                
                // 3. Find manifest and content
                // The ZIP might have a top-level folder (from our export) or files directly
                var contentDir = tempDir
                let items = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                if items.count == 1, items[0].hasDirectoryPath {
                    contentDir = items[0]
                }
                
                let manifestURL = contentDir.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else {
                    throw NSError(domain: "Import", code: 2, userInfo: [NSLocalizedDescriptionKey: "Manifest not found in archive"])
                }
                
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
                
                guard let title = manifest?["title"] as? String,
                      let textFile = manifest?["text_filename"] as? String else {
                    throw NSError(domain: "Import", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest format"])
                }
                
                // 4. Read text
                let textURL = contentDir.appendingPathComponent(textFile)
                let body = try String(contentsOf: textURL, encoding: .utf8)
                
                // 5. Create Entry
                let maxOrder = folder.entries.map { $0.sortOrder }.max() ?? -1
                let newEntry = Entry(title: title, body: body, sortOrder: maxOrder + 1, folder: folder)
                newEntry.bodyHash = FileHashing.sha256(string: body)
                modelContext.insert(newEntry)

                // 6. Handle Tokens
                if let tokensFile = manifest?["tokens_filename"] as? String, !tokensFile.isEmpty {
                    let tokensURL = contentDir.appendingPathComponent(tokensFile)
                    if fm.fileExists(atPath: tokensURL.path) {
                        newEntry.tokens = try Data(contentsOf: tokensURL)
                    }
                }

                // 7. Handle Audio
                if let audioFile = manifest?["audio_filename"] as? String, !audioFile.isEmpty {
                    let audioURL = contentDir.appendingPathComponent(audioFile)
                    if fm.fileExists(atPath: audioURL.path) {
                        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        // Use UUID for filename to avoid collisions and be consistent with TTSService
                        let ext = audioURL.pathExtension
                        let uniqueName = "\(UUID().uuidString).\(ext)"
                        let destinationURL = docsURL.appendingPathComponent(uniqueName)

                        try fm.copyItem(at: audioURL, to: destinationURL)
                        newEntry.audioFileURL = destinationURL
                        newEntry.audioHash = try? FileHashing.sha256(url: destinationURL)
                        if let attrs = try? fm.attributesOfItem(atPath: destinationURL.path) {
                            newEntry.fileSize = attrs[.size] as? Int64
                        }
                    }
                }
                
                await MainActor.run {
                    isImporting = false
                }
                
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func deleteEntry(_ entry: Entry) {
        withAnimation {
            DeletionService.delete(entry, in: modelContext)
        }
    }
}
