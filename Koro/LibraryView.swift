import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

enum DisplayMode: String, CaseIterable {
    case list = "list"
    case grid = "grid"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.sortOrder, order: .forward) private var folders: [Folder]
    @AppStorage("libraryDisplayMode") private var displayMode: DisplayMode = .grid

    @State private var showingAddFolder = false
    @State private var folderToDelete: Folder?
    @State private var showingDeleteConfirmation = false
    @State private var folderToEdit: Folder?
    @State private var showingSettings = false
    @State private var showingSync = false

    let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if displayMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
            .navigationTitle("Library")
            .sheet(isPresented: $showingSettings) {
                LibrarySettingsView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingSync) {
                SyncView()
            }
            .sheet(isPresented: $showingAddFolder) {
                FolderEditView { name, icon, imageName in
                    addFolder(name: name, icon: icon, imageName: imageName)
                }
            }
            .sheet(item: $folderToEdit) { folder in
                FolderEditView(folder: folder) { name, icon, imageName in
                    folder.name = name
                    folder.iconName = icon
                    
                    if let imageName {
                        // Delete old image if it exists and is different
                        if let old = folder.coverImageName, old != imageName {
                            CoverImageManager.shared.deleteImage(named: old)
                        }
                        folder.coverImageName = imageName
                        if let url = CoverImageManager.shared.getURL(for: imageName) {
                            folder.coverHash = try? FileHashing.sha256(url: url)
                        } else {
                            folder.coverHash = nil
                        }
                    } else {
                        if let old = folder.coverImageName {
                            CoverImageManager.shared.deleteImage(named: old)
                        }
                        folder.coverImageName = nil
                        folder.coverHash = nil
                    }
                    
                    folder.markAsUpdated()
                }
            }
            .alert("Delete Folder", isPresented: $showingDeleteConfirmation, presenting: folderToDelete) { folder in
                Button("Delete", role: .destructive) {
                    deleteFolder(folder)
                }
                Button("Cancel", role: .cancel) {
                    folderToDelete = nil
                }
            } message: { folder in
                Text("Are you sure you want to delete '\(folder.name)' and all its \(folder.entries.count) entries? This action cannot be undone.")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: { showingSync = true }) {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button(action: { showingSettings = true }) {
                            Label("Settings", systemImage: "gear")
                        }

                        Button(action: { showingAddFolder = true }) {
                            Label("Add Folder", systemImage: "plus")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder.badge.plus", description: Text("Tap the + button to create a new folder."))
                }
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 25) {
                ForEach(folders) { folder in
                    NavigationLink(destination: FolderView(folder: folder)) {
                        CoverView(
                            title: folder.name,
                            imageName: folder.coverImageName,
                            size: 160,
                            isFolder: true,
                            iconName: folder.iconName
                        )
                        .overlay(alignment: .topTrailing) {
                            if folder.entries.count > 0 {
                                Text("\(folder.entries.count)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .padding(8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            folderToEdit = folder
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            folderToDelete = folder
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
            ForEach(folders) { folder in
                NavigationLink(destination: FolderView(folder: folder)) {
                    HStack(spacing: 12) {
                        if let imageName = folder.coverImageName, let url = CoverImageManager.shared.getURL(for: imageName), let uiImage = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: folder.iconName)
                                .foregroundColor(stableColor(for: folder.name))
                                .font(.title3)
                                .frame(width: 32)
                        }

                        VStack(alignment: .leading) {
                            Text(folder.name)
                                .font(.headline)
                            Text("\(folder.entries.count) entries")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        folderToDelete = folder
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        folderToEdit = folder
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
            .onMove(perform: moveFolders)
        }
    }

    private func stableColor(for title: String) -> Color {
        var hash: UInt32 = 0
        for byte in title.utf8 {
            hash = (hash &+ UInt32(byte)).shl(5) &- (hash &+ UInt32(byte))
        }
        let hue = Double(abs(Int(hash)) % 360) / 360.0
        return Color(hue: hue, saturation: 0.4, brightness: 0.8)
    }

    private func addFolder(name: String, icon: String, imageName: String?) {
        withAnimation {
            let maxOrder = folders.map { $0.sortOrder }.max() ?? -1
            let newFolder = Folder(name: name, sortOrder: maxOrder + 1, coverImageName: imageName, iconName: icon)
            if let imageName, let url = CoverImageManager.shared.getURL(for: imageName) {
                newFolder.coverHash = try? FileHashing.sha256(url: url)
            }
            modelContext.insert(newFolder)
        }
    }

    private func deleteFolder(_ folder: Folder) {
        withAnimation {
            DeletionService.delete(folder, in: modelContext)
        }
    }

    private func moveFolders(from source: IndexSet, to destination: Int) {
        var revisedFolders = folders
        revisedFolders.move(fromOffsets: source, toOffset: destination)

        for reverseIndex in 0..<revisedFolders.count {
            revisedFolders[reverseIndex].sortOrder = reverseIndex
            revisedFolders[reverseIndex].markAsUpdated()
        }

        try? modelContext.save()
    }
}

struct FolderEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedIcon: String
    @State private var selectedItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var coverImageName: String?

    let onSave: (String, String, String?) -> Void

    let icons = [
        "folder.fill", "book.fill", "books.vertical.fill",
        "newspaper.fill", "doc.text.fill", "globe",
        "mic.fill", "antenna.radiowaves.left.and.right", "airpodspro",
        "graduationcap.fill", "briefcase.fill", "heart.fill"
    ]

    init(folder: Folder? = nil, onSave: @escaping (String, String, String?) -> Void) {
        _name = State(initialValue: folder?.name ?? "")
        _selectedIcon = State(initialValue: folder?.iconName ?? "folder.fill")
        _coverImageName = State(initialValue: folder?.coverImageName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CoverView(
                            title: name.isEmpty ? "New Folder" : name,
                            imageName: coverImageName,
                            size: 120,
                            isFolder: true,
                            iconName: selectedIcon
                        )
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical)

                    Menu {
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        }

                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Choose from Files", systemImage: "folder")
                        }
                    } label: {
                        Label(coverImageName == nil ? "Set Cover Image" : "Change Cover Image", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }

                    if coverImageName != nil {
                        Button(role: .destructive) {
                            if let name = coverImageName {
                                CoverImageManager.shared.deleteImage(named: name)
                            }
                            coverImageName = nil
                        } label: {
                            Text("Remove Cover Image")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Section("Folder Details") {
                    TextField("Name", text: $name)
                }

                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 20) {
                        ForEach(icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.title2)
                                .padding(8)
                                .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture {
                                    selectedIcon = icon
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(name.isEmpty ? "New Folder" : "Edit Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(name, selectedIcon, coverImageName)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }

                    if let data = try? Data(contentsOf: url),
                       let image = UIImage(data: data) {
                        updateCoverImage(image)
                    }
                case .failure(let error):
                    print("File import failed: \(error.localizedDescription)")
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        updateCoverImage(image)
                    }
                }
            }
        }
    }

    private func updateCoverImage(_ image: UIImage) {
        if let old = coverImageName {
            CoverImageManager.shared.deleteImage(named: old)
        }
        coverImageName = CoverImageManager.shared.saveImage(image)
    }
}

struct LibrarySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("libraryDisplayMode") private var libraryDisplayMode: DisplayMode = .grid
    @AppStorage("entryDisplayMode") private var entryDisplayMode: DisplayMode = .grid

    @State private var isExporting = false
    @State private var exportItems: [URL] = []
    @State private var isSharing = false

    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Appearance")) {
                    Picker("Library View", selection: $libraryDisplayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue.capitalized, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }

                    Picker("Entries View", selection: $entryDisplayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue.capitalized, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                }

                Section(header: Text("Data Management")) {
                    Button(action: exportBackup) {
                        HStack {
                            Label("Export Full Backup", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting || isImporting)

                    Button(action: { showingImporter = true }) {
                        HStack {
                            Label("Import Full Backup", systemImage: "square.and.arrow.down")
                            Spacer()
                            if isImporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting || isImporting)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isSharing) {
                ShareSheet(activityItems: exportItems)
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.korobackup]) { result in
                switch result {
                case .success(let url):
                    importBackup(from: url)
                case .failure(let error):
                    actionError = error.localizedDescription
                }
            }
            .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                if let actionError {
                    Text(actionError)
                }
            }
        }
    }

    private func exportBackup() {
        isExporting = true
        actionError = nil

        Task {
            do {
                let url = try await BackupManager.shared.createBackup(modelContext: modelContext)
                await MainActor.run {
                    self.exportItems = [url]
                    self.isSharing = true
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.actionError = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }

    private func importBackup(from url: URL) {
        isImporting = true
        actionError = nil

        Task {
            do {
                try await BackupManager.shared.restoreBackup(from: url, modelContext: modelContext)
                await MainActor.run {
                    self.isImporting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.actionError = error.localizedDescription
                    self.isImporting = false
                }
            }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Folder.self, Entry.self, Tombstone.self], inMemory: true)
}

private extension UInt32 {
    func shl(_ bits: UInt32) -> UInt32 {
        return (self << bits) | (self >> (32 - bits))
    }
}
