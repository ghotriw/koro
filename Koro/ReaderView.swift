import SwiftUI
import AVFoundation
import SwiftData
import MediaPlayer
import Combine
import MLX

enum ReaderFontDesign: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case serif = "Serif"
    case monospaced = "Monospaced"
    case rounded = "Rounded"
    var id: String { self.rawValue }

    var uiFontDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .standard: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        case .rounded: return .rounded
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case soft = "Soft"
    case dim = "Dim"

    var id: String { self.rawValue }

    var color: Color {
        switch self {
        case .system: return Color(UIColor.systemBackground)
        case .soft: return Color(UIColor.secondarySystemBackground)
        case .dim: return Color(UIColor.tertiarySystemBackground)
        }
    }
}

enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow = "Yellow"
    case blue = "Blue"
    case green = "Green"
    case pink = "Pink"
    case purple = "Purple"

    var id: String { self.rawValue }

    var uiColor: UIColor {
        switch self {
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .pink: return .systemPink
        case .purple: return .systemPurple
        }
    }
}

class PlaybackViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var currentTime: TimeInterval = 0
    @Published var isPlaying = false
    @Published var activeRange: NSRange?
    @Published var wordTokens: [WordToken] = []

    private var timeObserver: Any?
    private let entry: Entry

    init(entry: Entry) {
        self.entry = entry
        loadTokens()
        setupAudioSession()
    }

    deinit {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        MPRemoteCommandCenter.shared().playCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().skipForwardCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().skipBackwardCommand.removeTarget(nil)
    }

    func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ Failed to set audio session category: \(error)")
        }
    }

    func loadTokens() {
        guard let data = entry.tokens else { return }
        let decoder = JSONDecoder()
        do {
            let decoded = try decoder.decode([WordToken].self, from: data)
            self.wordTokens = decoded
        } catch {
            print("❌ ReaderView: Failed to decode tokens: \(error)")
        }
    }

    func setupPlayer() {
        guard let savedURL = entry.audioFileURL else { return }

        // Reconstruct the URL to handle iOS Sandbox path changes across app launches
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let currentURL = documentsURL.appendingPathComponent(savedURL.lastPathComponent)

        if !fileManager.fileExists(atPath: currentURL.path) {
            print("❌ Audio file NOT found at: \(currentURL.path)")
            return
        }

        let playerItem = AVPlayerItem(url: currentURL)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player

        if let lastPos = entry.lastPosition, lastPos > 0 {
            player.seek(to: CMTime(seconds: lastPos, preferredTimescale: 600))
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            self.updateHighlight(at: time.seconds)
            self.updateNowPlayingPlaybackValues()
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            self?.isPlaying = false
            self?.player?.seek(to: .zero)
            self?.updateNowPlayingInfo()
        }

        setupRemoteCommandCenter()
        updateNowPlayingInfo()
    }

    func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func skip(by seconds: TimeInterval) {
        let newTime = max(0, currentTime + seconds)
        player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func seekToWord(at nsRange: NSRange) {
        if let token = wordTokens.first(where: { NSIntersectionRange($0.nsRange, nsRange).length > 0 }) {
            player?.seek(to: CMTime(seconds: token.startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if !isPlaying {
                togglePlayback()
            }
        }
    }

    private func updateHighlight(at time: TimeInterval) {
        let token = wordTokens.first { $0.startTime <= time && time < $0.endTime }
        if let token = token {
            if activeRange != token.nsRange {
                activeRange = token.nsRange
            }
        } else {
            activeRange = nil
        }
    }

    // MARK: - Now Playing & Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.togglePlayback()
                return .success
            }
            return .commandFailed
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying {
                self.togglePlayback()
                return .success
            }
            return .commandFailed
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 10)
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -10)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = entry.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = entry.folder?.name ?? "Koro"

        if let duration = player?.currentItem?.duration.seconds, !duration.isNaN {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingPlaybackValues() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

struct ReaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var entry: Entry
    @StateObject private var viewModel: PlaybackViewModel
    @ObservedObject private var ttsService = TTSService.shared

    init(entry: Entry) {
        self.entry = entry
        _viewModel = StateObject(wrappedValue: PlaybackViewModel(entry: entry))
    }

    // Reader appearance
    @AppStorage("readerFontSize") private var fontSize: Double = 20
    @AppStorage("readerLineSpacing") private var lineSpacing: Double = 1.2
    @AppStorage("readerFontDesign") private var fontDesign: ReaderFontDesign = .standard
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    @AppStorage("readerTextOpacity") private var textOpacity: Double = 1.0
    @AppStorage("readerHighlightColor") private var highlightColor: HighlightColor = .yellow
    @State private var showingSettings = false

    // Generation
    @AppStorage("lastSelectedVoice") private var selectedVoice = "af_heart"
    @AppStorage("lastSelectedSpeed") private var selectedSpeed: Double = 1.0
    @AppStorage("ttsBaseChunkSize") private var ttsBaseChunkSize: Int = 400
    @AppStorage("mlxMemoryLimit") private var mlxMemoryLimit: Int = 900
    @AppStorage("mlxCacheLimit") private var mlxCacheLimit: Int = 50
    @State private var showingGenerationSheet = false
    @State private var errorMessage: String?

    // Edit / share
    @State private var showingEditSheet = false
    @State private var isSharing = false
    @State private var exportItems: [URL] = []
    @State private var isExporting = false

    private var hasAudio: Bool { entry.audioFileURL != nil }

    var body: some View {
        Group {
            if hasAudio {
                readyContent
            } else {
                emptyContent
            }
        }
        .background(theme.color)
        .ignoresSafeArea(edges: hasAudio ? .all : [])
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "textformat.size")
                    }

                    Menu {
                        Button {
                            showingEditSheet = true
                        } label: {
                            Label("Edit Text", systemImage: "pencil")
                        }

                        if hasAudio {
                            Button {
                                showingGenerationSheet = true
                            } label: {
                                Label("Regenerate Audio", systemImage: "arrow.clockwise")
                            }
                            .disabled(ttsService.isGenerating)

                            Button {
                                exportData()
                            } label: {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                            .disabled(isExporting)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }

            if hasAudio {
                ToolbarItem(placement: .bottomBar) {
                    playerControls
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(fontSize: $fontSize, lineSpacing: $lineSpacing, fontDesign: $fontDesign, theme: $theme, textOpacity: $textOpacity, highlightColor: $highlightColor)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingEditSheet) {
            NavigationStack {
                EntryEditView(entry: entry)
            }
        }
        .sheet(isPresented: $showingGenerationSheet) {
            generationSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isSharing) {
            ShareSheet(activityItems: exportItems)
        }
        .toolbarBackground(.regularMaterial, for: .bottomBar)
        .toolbarBackground(hasAudio ? .visible : .hidden, for: .bottomBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ttsService.isGenerating {
                generationProgress
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .onAppear {
            if hasAudio {
                viewModel.setupPlayer()
            }
        }
        .onChange(of: entry.audioFileURL) { _, newValue in
            if newValue != nil {
                viewModel.loadTokens()
                viewModel.setupPlayer()
            }
        }
        .onDisappear {
            if hasAudio {
                entry.lastPosition = viewModel.currentTime
                entry.lastPositionUpdatedAt = .now
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background, hasAudio {
                entry.lastPosition = viewModel.currentTime
                entry.lastPositionUpdatedAt = .now
            }
        }
    }

    // MARK: - Ready (text + player)

    private var readyContent: some View {
        TranscriptTextView(
            text: entry.body,
            activeRange: viewModel.activeRange,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            fontDesign: fontDesign,
            textOpacity: textOpacity,
            highlightColor: highlightColor,
            onWordTapped: viewModel.seekToWord
        )
    }

    private var playerControls: some View {
        HStack {
            Spacer()
            HStack(spacing: 50) {
                Button(action: { viewModel.skip(by: -10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                Button(action: { viewModel.skip(by: 10) }) {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
            }
            Spacer()
        }
    }

    // MARK: - Empty / Generating

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                Text(entry.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)

            if !ttsService.isGenerating {
                HStack {
                    Spacer()
                    Button {
                        showingGenerationSheet = true
                    } label: {
                        Label("Generate Audio", systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(entry.body.isEmpty)
                    Spacer()
                }
            }

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if isExporting {
                HStack {
                    ProgressView().padding(.trailing, 8)
                    Text("Preparing archive…")
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
    }

    private var generationProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Generating Audio…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let eta = ttsService.estimatedTimeRemaining {
                    Text("\(formatTime(eta)) left")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("\(Int(ttsService.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ProgressView(value: ttsService.progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Generation sheet

    private var generationSheet: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Picker("Select Voice", selection: $selectedVoice) {
                        if ttsService.availableVoices.isEmpty {
                            Text("Loading voices…").tag("af_heart")
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

                Section(header: Text("Advanced (TTS & Memory)"),
                        footer: Text("Lower chunk size if you experience memory issues. Higher GPU limits improve speed but may cause crashes.")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Base Chunk Size")
                            Spacer()
                            Text("\(ttsBaseChunkSize) chars").foregroundColor(.secondary)
                        }
                        Slider(value: Binding(get: { Double(ttsBaseChunkSize) },
                                              set: { ttsBaseChunkSize = Int($0) }),
                               in: 100...500, step: 10)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("GPU Memory")
                            Spacer()
                            Text("\(mlxMemoryLimit) MB").foregroundColor(.secondary)
                        }
                        Slider(value: Binding(get: { Double(mlxMemoryLimit) },
                                              set: {
                                                  mlxMemoryLimit = Int($0)
                                                  GPU.set(memoryLimit: mlxMemoryLimit * 1024 * 1024)
                                              }),
                               in: 200...4000, step: 100)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("GPU Cache")
                            Spacer()
                            Text("\(mlxCacheLimit) MB").foregroundColor(.secondary)
                        }
                        Slider(value: Binding(get: { Double(mlxCacheLimit) },
                                              set: {
                                                  mlxCacheLimit = Int($0)
                                                  GPU.set(cacheLimit: mlxCacheLimit * 1024 * 1024)
                                              }),
                               in: 10...500, step: 10)
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
                    Button(ttsService.isReady ? "Start" : "Loading…") {
                        showingGenerationSheet = false
                        generateAudio()
                    }
                    .disabled(!ttsService.isReady)
                }
            }
            .onChange(of: ttsService.availableVoices) { _, newValue in
                if !newValue.isEmpty && !newValue.contains(where: { $0.id == selectedVoice }) {
                    if let first = newValue.first { selectedVoice = first.id }
                }
            }
            .onAppear {
                Task { await ttsService.prepareEngine() }
                if !ttsService.availableVoices.isEmpty &&
                    !ttsService.availableVoices.contains(where: { $0.id == selectedVoice }) {
                    selectedVoice = ttsService.availableVoices.first!.id
                }
            }
        }
    }

    // MARK: - Actions

    private func generateAudio() {
        errorMessage = nil
        Task {
            do {
                try await ttsService.generateAudio(for: entry,
                                                   voiceName: selectedVoice,
                                                   speed: Float(selectedSpeed))
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

        var exportedAudioFileName: String? = nil
        if let savedURL = entry.audioFileURL {
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

        let textFileName = "\(safeTitle).txt"
        let textURL = folderURL.appendingPathComponent(textFileName)
        try? entry.body.write(to: textURL, atomically: true, encoding: .utf8)

        var tokensFileName: String? = nil
        if let tokensData = entry.tokens {
            let name = "\(safeTitle)_tokens.json"
            tokensFileName = name
            let tokensURL = folderURL.appendingPathComponent(name)
            try? tokensData.write(to: tokensURL)
        }

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

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

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

    private func formatTime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

struct SettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var fontDesign: ReaderFontDesign
    @Binding var theme: ReaderTheme
    @Binding var textOpacity: Double
    @Binding var highlightColor: HighlightColor

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Background", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Highlight Color", selection: $highlightColor) {
                        ForEach(HighlightColor.allCases) { color in
                            Text(color.rawValue).tag(color)
                        }
                    }
                }

                Section("Typography") {
                    Picker("Font Style", selection: $fontDesign) {
                        ForEach(ReaderFontDesign.allCases) { design in
                            Text(design.rawValue).tag(design)
                        }
                    }
                }

                Section("Text Settings") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $fontSize, in: 14...32, step: 1)
                        Image(systemName: "textformat.size.larger")
                    }

                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                        Slider(value: $textOpacity, in: 0.3...1.0, step: 0.05)
                        Text("\(Int(textOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "line.3.horizontal")
                        Slider(value: $lineSpacing, in: 1.0...2.0, step: 0.1)
                        Text(String(format: "%.1fx", lineSpacing))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Reader Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct TranscriptTextView: UIViewRepresentable {
    let text: String
    var activeRange: NSRange?
    let fontSize: Double
    let lineSpacing: Double
    let fontDesign: ReaderFontDesign
    let textOpacity: Double
    let highlightColor: HighlightColor
    var onWordTapped: (NSRange) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear

        textView.clipsToBounds = false
        textView.showsVerticalScrollIndicator = true
        textView.contentInsetAdjustmentBehavior = .always

        textView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 400, right: 0)
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 20, bottom: 0, right: 20)

        textView.delegate = context.coordinator

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tapGesture)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator

        // Check if visual settings changed
        let settingsChanged = coordinator.lastFontSize != fontSize ||
                              coordinator.lastLineSpacing != lineSpacing ||
                              coordinator.lastFontDesign != fontDesign ||
                              coordinator.lastTextOpacity != textOpacity ||
                              coordinator.lastText != text

        if settingsChanged {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineHeightMultiple = CGFloat(lineSpacing)

            let baseFont = UIFont.systemFont(ofSize: CGFloat(fontSize))
            let fontDescriptor = baseFont.fontDescriptor.withDesign(fontDesign.uiFontDesign) ?? baseFont.fontDescriptor
            let finalFont = UIFont(descriptor: fontDescriptor, size: CGFloat(fontSize))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: finalFont,
                .foregroundColor: UIColor.label.withAlphaComponent(CGFloat(textOpacity)),
                .paragraphStyle: paragraphStyle
            ]

            uiView.attributedText = NSAttributedString(string: text, attributes: attributes)

            coordinator.lastFontSize = fontSize
            coordinator.lastLineSpacing = lineSpacing
            coordinator.lastFontDesign = fontDesign
            coordinator.lastTextOpacity = textOpacity
            coordinator.lastText = text
            // Reset active range so it gets re-highlighted
            coordinator.lastActiveRange = nil
        }

        // Handle highlight updates without resetting the entire text view
        if coordinator.lastActiveRange != activeRange || coordinator.lastHighlightColor != highlightColor {
            let storage = uiView.textStorage

            // 1. Remove old highlight
            if let oldRange = coordinator.lastActiveRange, oldRange.location + oldRange.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: oldRange)
            }

            // 2. Apply new highlight
            if let range = activeRange, range.location + range.length <= storage.length {
                storage.addAttribute(.backgroundColor, value: highlightColor.uiColor.withAlphaComponent(0.4), range: range)

                // 3. Scroll if needed (auto-center logic)
                let now = Date()
                if now.timeIntervalSince(coordinator.lastUserInteraction) > 3.0 {
                    scrollToRange(range, in: uiView)
                }
            }

            coordinator.lastActiveRange = activeRange
            coordinator.lastHighlightColor = highlightColor
        }
    }

    private func scrollToRange(_ range: NSRange, in textView: UITextView) {
        guard let layoutManager = textView.textLayoutManager,
              let textContentManager = layoutManager.textContentManager else { return }

        guard let start = textContentManager.location(textContentManager.documentRange.location, offsetBy: range.location),
              let end = textContentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }

        // CRITICAL FIX: Ensure layout is computed from the beginning to the current word.
        // TextKit 2 uses estimated heights for fragments that haven't been laid out yet.
        // Custom lineSpacing (lineHeightMultiple) often causes these estimates to be wrong,
        // leading to accumulated drift as we move further into a large text.
        if let headRange = NSTextRange(location: textContentManager.documentRange.location, end: end) {
            layoutManager.ensureLayout(for: headRange)
        }

        var wordRect = CGRect.null

        // Find the precise rect of the word segment
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { range, rect, _, _ in
            wordRect = rect
            return false // We just need the first segment of the word
        }

        guard !wordRect.isNull else { return }

        // Calculate target offset:
        // wordRect.origin.y is relative to the text layout
        // We add textContainerInset.top because contentOffset starts from the top of the view
        let wordYInTextView = wordRect.origin.y + textView.textContainerInset.top
        let targetY = wordYInTextView - (textView.bounds.height / 3.0)

        // Clamp the scroll to prevent bounce-back issues at the very top.
        // We use adjustedContentInset because contentInsetAdjustmentBehavior is .always,
        // which accounts for the safe area (navigation bar, etc.)
        let minOffset = -textView.adjustedContentInset.top
        let maxOffset = textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom
        let clampedY = max(minOffset, min(targetY, maxOffset))

        UIView.animate(withDuration: 0.6, delay: 0, options: [.allowUserInteraction, .curveEaseOut], animations: {
            textView.contentOffset = CGPoint(x: 0, y: clampedY)
        })
    }
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: TranscriptTextView
        var lastUserInteraction = Date.distantPast

        // State tracking to optimize updates
        var lastFontSize: Double?
        var lastLineSpacing: Double?
        var lastFontDesign: ReaderFontDesign?
        var lastTextOpacity: Double?
        var lastText: String?
        var lastActiveRange: NSRange?
        var lastHighlightColor: HighlightColor?

        init(_ parent: TranscriptTextView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }

            if textView.selectedRange.length > 0 {
                textView.selectedTextRange = nil
                return
            }

            let point = gesture.location(in: textView)

            // Final Pure TextKit 2 hit-testing implementation
            guard let layoutManager = textView.textLayoutManager,
                  let textContentManager = layoutManager.textContentManager else { return }

            // 1. Adjust point for container insets
            let adjustedPoint = CGPoint(x: point.x - textView.textContainerInset.left,
                                        y: point.y - textView.textContainerInset.top)

            // 2. Use the documented TextKit 2 API for semantic word selection
            let navigation = layoutManager.textSelectionNavigation
            guard let selection = navigation.textSelection(for: .word,
                                                           enclosing: adjustedPoint,
                                                           inContainerAt: textContentManager.documentRange.location),
                  let textRange = selection.textRanges.first else {
                return
            }

            // 3. Convert NSTextRange to NSRange
            let startOffset = textContentManager.offset(from: textContentManager.documentRange.location, to: textRange.location)
            let endOffset = textContentManager.offset(from: textContentManager.documentRange.location, to: textRange.endLocation)
            let nsRange = NSRange(location: startOffset, length: endOffset - startOffset)

            lastUserInteraction = Date()
            parent.onWordTapped(nsRange)
        }


        // Detect manual scrolling
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            lastUserInteraction = Date()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            lastUserInteraction = Date()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            lastUserInteraction = Date()
        }
    }
}

extension UITextView {
    func nsRange(from range: UITextRange) -> NSRange? {
        let location = self.offset(from: self.beginningOfDocument, to: range.start)
        let length = self.offset(from: range.start, to: range.end)
        return NSRange(location: location, length: length)
    }
}
