import SwiftUI
import AVFoundation
import SwiftData
import MediaPlayer
import Combine

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
    let entry: Entry
    @StateObject private var viewModel: PlaybackViewModel

    init(entry: Entry) {
        self.entry = entry
        _viewModel = StateObject(wrappedValue: PlaybackViewModel(entry: entry))
    }

    // Settings persistence
    @AppStorage("readerFontSize") private var fontSize: Double = 20
    @AppStorage("readerLineSpacing") private var lineSpacing: Double = 1.2
    @AppStorage("readerFontDesign") private var fontDesign: ReaderFontDesign = .standard
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    @AppStorage("readerTextOpacity") private var textOpacity: Double = 1.0
    @AppStorage("readerHighlightColor") private var highlightColor: HighlightColor = .yellow
    @State private var showingSettings = false

    var body: some View {
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
        .background(theme.color)
        .ignoresSafeArea()
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "textformat.size")
                }
            }

            ToolbarItem(placement: .bottomBar) {
                playerControls
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(fontSize: $fontSize, lineSpacing: $lineSpacing, fontDesign: $fontDesign, theme: $theme, textOpacity: $textOpacity, highlightColor: $highlightColor)
                .presentationDetents([.medium, .large])
        }
        .toolbarBackground(.regularMaterial, for: .bottomBar)
        .toolbarBackground(.visible, for: .bottomBar)
        .onAppear {
            viewModel.setupPlayer()
        }
        .onDisappear {
            entry.lastPosition = viewModel.currentTime
            entry.lastPositionUpdatedAt = .now
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                entry.lastPosition = viewModel.currentTime
                entry.lastPositionUpdatedAt = .now
            }
        }
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
