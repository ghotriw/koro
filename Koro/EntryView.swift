import SwiftUI
import SwiftData
import MLX

struct EntryEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let folder: Folder

    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        Form {
            Section("Details") {
                TextField("Title", text: $title)
                TextEditor(text: $bodyText)
                    .frame(minHeight: 200)
            }
        }
        .navigationTitle("New Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    addEntry()
                    dismiss()
                }
                .disabled(title.isEmpty || bodyText.isEmpty)
            }
        }
    }

    private func addEntry() {
        let maxOrder = folder.entries.map { $0.sortOrder }.max() ?? -1
        let newEntry = Entry(title: title, body: bodyText, sortOrder: maxOrder + 1, folder: folder)
        modelContext.insert(newEntry)
    }
}

struct EntryView: View {
    @Bindable var entry: Entry
    @State private var isEditing = false
    @ObservedObject private var ttsService = TTSService.shared
    @State private var errorMessage: String?

    @State private var showingGenerationSheet = false
    @AppStorage("lastSelectedVoice") private var selectedVoice = "af_heart"
    @AppStorage("lastSelectedSpeed") private var selectedSpeed: Double = 1.0
    
    // TTS & Performance Settings
    @AppStorage("ttsBaseChunkSize") private var ttsBaseChunkSize: Int = 400
    @AppStorage("mlxMemoryLimit") private var mlxMemoryLimit: Int = 900
    @AppStorage("mlxCacheLimit") private var mlxCacheLimit: Int = 50

    @State private var isSharing = false
    @State private var exportItems: [URL] = []
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if isEditing {
                    TextField("Title", text: $entry.title)
                        .font(.title)
                        .textFieldStyle(.roundedBorder)

                    TextEditor(text: $entry.body)
                        .frame(minHeight: 300)
                        .border(Color.gray.opacity(0.2))
                } else {
                    Text(entry.title)
                        .font(.title)
                        .bold()
                        .textSelection(.enabled)

                    ScrollView {
                        Text(entry.body)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 350)
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                }

                if ttsService.isGenerating {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Generating Audio...", systemImage: "waveform")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(ttsService.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: ttsService.progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                if isExporting {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Preparing archive...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding()
            
            Spacer()
        }
        .onAppear {
            // Ensure engine is ready when entering the view
            Task {
                await ttsService.prepareEngine()
            }
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if entry.audioFileURL != nil {
                        Button(action: {
                            exportData()
                        }) {
                            if isExporting {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(isExporting)
                    }
                    
                    Button(isEditing ? "Done" : "Edit") {
                        isEditing.toggle()
                    }
                }
            }

            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 20) {
                    if entry.audioFileURL == nil {
                        Button(action: {
                            showingGenerationSheet = true
                        }) {
                            Label(ttsService.isReady ? "Generate Audio" : "Loading Engine...", systemImage: "waveform.badge.plus")
                        }
                        .disabled(ttsService.isGenerating || entry.body.isEmpty)
                    } else {
                        Button(action: {
                            showingGenerationSheet = true
                        }) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .disabled(ttsService.isGenerating)

                        NavigationLink(destination: ReaderView(entry: entry)) {
                            Label("Read & Listen", systemImage: "play.circle.fill")
                                .font(.title2)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingGenerationSheet) {
            NavigationStack {
                Form {
                    Section("Voice") {
                        Picker("Select Voice", selection: $selectedVoice) {
                            if ttsService.availableVoices.isEmpty {
                                Text("Loading voices...").tag("af_heart")
                            } else {
                                ForEach(ttsService.availableVoices) { voice in
                                    Text(voice.displayName).tag(voice.id)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section("Speed: \(String(format: "%.1f", selectedSpeed))x") {
                        Slider(value: $selectedSpeed, in: 0.5...2.0, step: 0.1)
                    }
                    
                    Section(header: Text("Advanced (TTS & Memory)"), footer: Text("Lower chunk size if you experience memory issues. Higher GPU limits improve speed but may cause crashes.")) {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Base Chunk Size")
                                Spacer()
                                Text("\(ttsBaseChunkSize) chars")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(get: {
                                Double(ttsBaseChunkSize)
                            }, set: {
                                ttsBaseChunkSize = Int($0)
                            }), in: 100...500, step: 10)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("GPU Memory")
                                Spacer()
                                Text("\(mlxMemoryLimit) MB")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(get: {
                                Double(mlxMemoryLimit)
                            }, set: {
                                mlxMemoryLimit = Int($0)
                                GPU.set(memoryLimit: mlxMemoryLimit * 1024 * 1024)
                            }), in: 200...4000, step: 100)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("GPU Cache")
                                Spacer()
                                Text("\(mlxCacheLimit) MB")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(get: {
                                Double(mlxCacheLimit)
                            }, set: {
                                mlxCacheLimit = Int($0)
                                GPU.set(cacheLimit: mlxCacheLimit * 1024 * 1024)
                            }), in: 10...500, step: 10)
                        }
                        
                        Button("Reset to Defaults") {
                            ttsBaseChunkSize = 400
                            mlxMemoryLimit = 900
                            mlxCacheLimit = 50
                            GPU.set(memoryLimit: 900 * 1024 * 1024)
                            GPU.set(cacheLimit: 50 * 1024 * 1024)
                        }
                        .foregroundColor(.red)
                    }
                }
                .navigationTitle("Generation Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingGenerationSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") {
                            showingGenerationSheet = false
                            generateAudio()
                        }
                        .disabled(!ttsService.isReady)
                    }
                }
                .onChange(of: ttsService.availableVoices) { oldValue, newValue in
                    // Only auto-select if current selection is not in the new list AND we actually have voices
                    if !newValue.isEmpty && !newValue.contains(where: { $0.id == selectedVoice }) {
                        if let first = newValue.first {
                            selectedVoice = first.id
                        }
                    }
                }
                .onAppear {
                    // Default only if current selection is missing and voices are loaded
                    if !ttsService.availableVoices.isEmpty && !ttsService.availableVoices.contains(where: { $0.id == selectedVoice }) {
                        selectedVoice = ttsService.availableVoices.first!.id
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isSharing) {
            ShareSheet(activityItems: exportItems)
        }
        .onChange(of: entry.title) { _, _ in
            entry.markAsUpdated()
        }
        .onChange(of: entry.body) { _, _ in
            // Invalidate stale audio/tokens when body changes; remove the audio file from disk too
            if let oldURL = entry.audioFileURL {
                let fm = FileManager.default
                let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let resolved = docs.appendingPathComponent(oldURL.lastPathComponent)
                try? fm.removeItem(at: resolved)
            }
            entry.tokens = nil
            entry.audioFileURL = nil
            entry.audioHash = nil
            entry.fileSize = nil
            entry.lastPosition = nil
            entry.bodyHash = FileHashing.sha256(string: entry.body)
            entry.markAsUpdated()
        }
    }

    private func generateAudio() {
        errorMessage = nil
        Task {
            do {
                try await ttsService.generateAudio(for: entry, voiceName: selectedVoice, speed: Float(selectedSpeed))
            } catch {
                print("❌ UI: Generation failed: \(error)")
                errorMessage = "Failed to generate audio: \(error.localizedDescription)"
            }
        }
    }

    private func exportData() {
        isExporting = true
        errorMessage = nil
        
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let safeTitle = entry.title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let folderURL = tempDir.appendingPathComponent(safeTitle)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        
        // 1. Audio
        var exportedAudioFileName: String? = nil
        if let savedURL = entry.audioFileURL {
            // Reconstruct the URL to handle iOS Sandbox path changes across app launches
            let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let currentAudioURL = documentsURL.appendingPathComponent(savedURL.lastPathComponent)
            
            if fm.fileExists(atPath: currentAudioURL.path) {
                let ext = currentAudioURL.pathExtension
                let audioName = "\(safeTitle).\(ext)"
                exportedAudioFileName = audioName
                let destAudio = folderURL.appendingPathComponent(audioName)
                try? fm.copyItem(at: currentAudioURL, to: destAudio)
            } else {
                print("❌ Export: Audio file NOT found at: \(currentAudioURL.path)")
            }
        }
        
        // 2. Text
        let textFileName = "\(safeTitle).txt"
        let textURL = folderURL.appendingPathComponent(textFileName)
        try? entry.body.write(to: textURL, atomically: true, encoding: .utf8)
        
        // 3. Tokens
        var tokensFileName: String? = nil
        if let tokensData = entry.tokens {
            let name = "\(safeTitle)_tokens.json"
            tokensFileName = name
            let tokensURL = folderURL.appendingPathComponent(name)
            try? tokensData.write(to: tokensURL)
        }

        // 4. Manifest
        let manifest: [String: Any] = [
            "version": 1,
            "title": entry.title,
            "audio_filename": exportedAudioFileName ?? "",
            "text_filename": textFileName,
            "tokens_filename": tokensFileName ?? ""
        ]
        
        if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            let manifestURL = folderURL.appendingPathComponent("manifest.json")
            try? manifestData.write(to: manifestURL)
        }
        
        // Use NSFileCoordinator to create a ZIP archive
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        
        // Important: coordinate is a blocking call. We should run it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.coordinate(readingItemAt: folderURL, options: .forUploading, error: &coordinatorError) { zipURL in
                let finalZipURL = tempDir.appendingPathComponent("\(safeTitle).zip")
                
                do {
                    try fm.copyItem(at: zipURL, to: finalZipURL)
                    
                    DispatchQueue.main.async {
                        self.exportItems = [finalZipURL]
                        self.isExporting = false
                        self.isSharing = true
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isExporting = false
                        self.errorMessage = "Failed to copy archive: \(error.localizedDescription)"
                    }
                }
            }
            
            if let error = coordinatorError {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.errorMessage = "Failed to create archive: \(error.localizedDescription)"
                }
            }
        }
    }
}
