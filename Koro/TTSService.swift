import Foundation
import OSLog
import UIKit
@preconcurrency import AVFoundation
import KokoroSwift
import MLX
import SwiftData
import Combine
import MLXUtilsLibrary

@MainActor
final class TTSService: ObservableObject {
    nonisolated static let log = Logger(subsystem: "com.koro.tts", category: "generation")

    nonisolated(unsafe) private var kokoro: KokoroTTS?
    nonisolated(unsafe) private var voices: [String: MLXArray] = [:]
    private var initializationTask: Task<Void, Never>?

    @Published var isGenerating = false
    @Published var isReady = false
    @Published var progress: Float = 0.0
    @Published var estimatedTimeRemaining: TimeInterval? = nil
    @Published var availableVoices: [VoiceInfo] = []

    private var unloadTask: Task<Void, Never>?

    static let shared = TTSService()

    struct VoiceInfo: Identifiable, Hashable, Codable {
        let id: String
        let name: String
        let flag: String
        let genderEmoji: String

        var displayName: String {
            "\(flag) \(genderEmoji) \(name)"
        }
    }

    // Helper struct for Swift 6 Concurrency to transport non-Sendable types
    private struct InitializationResult: @unchecked Sendable {
        let kokoro: KokoroTTS
        let voices: [String: MLXArray]
    }

    private let voiceMap: [String: (name: String, flag: String, gender: String)] = [
        "af_heart": ("Heart", "🇺🇸", "👩"),
        "af_alloy": ("Alloy", "🇺🇸", "👩"),
        "af_aoede": ("Aoede", "🇺🇸", "👩"),
        "af_bella": ("Bella", "🇺🇸", "👩"),
        "af_jessica": ("Jessica", "🇺🇸", "👩"),
        "af_kore": ("Kore", "🇺🇸", "👩"),
        "af_nicole": ("Nicole", "🇺🇸", "👩"),
        "af_nova": ("Nova", "🇺🇸", "👩"),
        "af_river": ("River", "🇺🇸", "👩"),
        "af_sky": ("Sky", "🇺🇸", "👩"),
        "am_adam": ("Adam", "🇺🇸", "👨"),
        "am_echo": ("Echo", "🇺🇸", "👨"),
        "am_eric": ("Eric", "🇺🇸", "👨"),
        "am_fenrir": ("Fenrir", "🇺🇸", "👨"),
        "am_liam": ("Liam", "🇺🇸", "👨"),
        "am_michael": ("Michael", "🇺🇸", "👨"),
        "am_onyx": ("Onyx", "🇺🇸", "👨"),
        "am_puck": ("Puck", "🇺🇸", "👨"),
        "am_santa": ("Santa", "🇺🇸", "👨"),
        "bf_alice": ("Alice", "🇬🇧", "👩"),
        "bf_emma": ("Emma", "🇬🇧", "👩"),
        "bf_isabella": ("Isabella", "🇬🇧", "👩"),
        "bf_lily": ("Lily", "🇬🇧", "👩"),
        "bm_daniel": ("Daniel", "🇬🇧", "👨"),
        "bm_fable": ("Fable", "🇬🇧", "👨"),
        "bm_george": ("George", "🇬🇧", "👨"),
        "bm_lewis": ("Lewis", "🇬🇧", "👨")
    ]

    private init() {
        // Engine is loaded on demand via prepareEngine() — call sites
        // (generation sheet onAppear, generateAudio()) trigger it explicitly.
    }

    func prepareEngine() async {
        unloadTask?.cancel()

        if isReady { return }

        // If we are currently initializing, await that task
        if let task = initializationTask {
            _ = await task.result
            return
        }

        // Otherwise, start initialization
        let task = Task {
            await performInitialization()
        }
        self.initializationTask = task
        _ = await task.result
    }

    private func performInitialization() async {
        // Double check isReady inside the task
        if isReady {
            self.initializationTask = nil
            return
        }

        Self.log.info("🚀 Starting TTS Engine initialization...")

        guard let modelURL = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors") else {
            Self.log.error("❌ Critical: kokoro-v1_0.safetensors not found in bundle.")
            return
        }

        guard let voicesURL = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            Self.log.error("❌ Critical: voices.npz not found in bundle.")
            return
        }

        let result = await Task.detached(priority: .userInitiated) { () -> InitializationResult in
            Self.log.info("📦 Loading model weights...")
            let kokoro = KokoroTTS(modelPath: modelURL)
            Self.log.info("🗣️ Loading voices...")
            let voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
            return InitializationResult(kokoro: kokoro, voices: voices)
        }.value

        // 4. Update state on MainActor
        self.kokoro = result.kokoro
        self.voices = result.voices

        // Only generate availableVoices if they haven't been loaded yet
        if self.availableVoices.isEmpty {
            let rawVoiceKeys = Array(result.voices.keys)
                .map { $0.replacingOccurrences(of: ".npy", with: "") }

            self.availableVoices = rawVoiceKeys.map { id in
                if let mapped = voiceMap[id] {
                    return VoiceInfo(id: id, name: mapped.name, flag: mapped.flag, genderEmoji: mapped.gender)
                } else {
                    // Fallback for unknown voices
                    let components = id.split(separator: "_")
                    let name = components.last?.capitalized ?? id
                    let flag = id.hasPrefix("a") ? "🇺🇸" : (id.hasPrefix("b") ? "🇬🇧" : "👤")

                    // Detect gender from second character (f/m)
                    let genderEmoji: String
                    if id.count > 1 {
                        let genderChar = id[id.index(id.startIndex, offsetBy: 1)]
                        genderEmoji = genderChar == "f" ? "👩" : (genderChar == "m" ? "👨" : "👤")
                    } else {
                        genderEmoji = "👤"
                    }

                    return VoiceInfo(id: id, name: String(name), flag: flag, genderEmoji: genderEmoji)
                }
            }.sorted { $0.name < $1.name }
        }

        self.isReady = true
        self.initializationTask = nil
        Self.log.info("✅ TTS Engine Ready with \(self.voices.count, privacy: .public) voices.")
    }

    func generateAudio(for entry: Entry, voiceName: String, speed: Float) async throws {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "KokoroTTSGeneration") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        UIApplication.shared.isIdleTimerDisabled = true

        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        // Ensure engine is ready before starting
        if !isReady {
            await prepareEngine()
        }

        guard let kokoro = kokoro else {
            Self.log.error("❌ Cannot generate audio: Engine not initialized")
            return
        }

        let fullVoiceName = voiceName.hasSuffix(".npy") ? voiceName : "\(voiceName).npy"
        guard let voiceArray = voices[fullVoiceName] else {
            Self.log.error("❌ Voice \(voiceName, privacy: .public) not found")
            return
        }

        isGenerating = true
        progress = 0.0
        estimatedTimeRemaining = nil

        let rawText = entry.body
        let cleanText = MarkdownTextHelper.cleanText(from: rawText)
        let text = normalizeText(cleanText)

        let chunks = splitIntoChunks(text, speed: speed)
        Self.log.info("📝 Split text into \(chunks.count, privacy: .public) chunks (speed: \(speed, privacy: .public))")

        let totalChars = text.count
        var charsDone = 0
        let startTime = Date()

        // Detect language based on voice ID prefix
        // a = American (enUS), b = British (enGB)
        let lang: Language = fullVoiceName.hasPrefix("b") ? .enGB : .enUS
        Self.log.info("🌐 Using language: \(lang == .enGB ? "British" : "American", privacy: .public)")

        var allWordTokens: [WordToken] = []
        var currentAudioTime: Double = 0
        var searchStartIndex = cleanText.startIndex

        // Prepare file for streaming
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Use a temporary CAF file for streaming
        let tempAudioURL = documentsURL.appendingPathComponent("\(entry.persistentModelID.hashValue)_temp.caf")
        // Final compressed destination
        let finalAudioURL = documentsURL.appendingPathComponent("\(entry.persistentModelID.hashValue).m4a")

        if fileManager.fileExists(atPath: tempAudioURL.path) {
            try? fileManager.removeItem(at: tempAudioURL)
        }
        if fileManager.fileExists(atPath: finalAudioURL.path) {
            try? fileManager.removeItem(at: finalAudioURL)
        }

        let sampleRate = 24000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Process chunks in a background task
        try await Task.detached(priority: .userInitiated) { [cleanText, voiceArray, lang, kokoro] in
            let audioFile = try AVAudioFile(forWriting: tempAudioURL, settings: format.settings)

            for (index, chunk) in chunks.enumerated() {
                try autoreleasepool {
                    Self.log.info("🔄 Starting chunk \(index + 1, privacy: .public)/\(chunks.count, privacy: .public) (length: \(chunk.count, privacy: .public) chars)")
                    let (audio, mTokens) = try kokoro.generateAudio(voice: voiceArray, language: lang, text: chunk, speed: speed)
                    if let mTokens {
                        let phonemeTokenCount = mTokens.reduce(0) { $0 + ($1.phonemes?.count ?? 0) }
                        let modelTokenCount = phonemeTokenCount + 2 // + BOS/EOS
                        let charsPerToken = modelTokenCount > 0 ? Double(chunk.count) / Double(modelTokenCount) : 0
                        Self.log.info("   🔢 Chunk \(index + 1, privacy: .public): \(modelTokenCount, privacy: .public) phoneme tokens, \(mTokens.count, privacy: .public) words, \(String(format: "%.2f", charsPerToken), privacy: .public) chars/token")
                    }

                    // Write audio buffer immediately to disk
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count))!
                    buffer.frameLength = buffer.frameCapacity
                    for i in 0..<audio.count {
                        buffer.floatChannelData![0][i] = audio[i]
                    }
                    try audioFile.write(from: buffer)

                    // Update tokens
                    if let mTokens = mTokens {
                        for mToken in mTokens {
                            let word = mToken.text
                            guard !word.isEmpty else { continue }

                            if let range = TTSService.findRange(for: word, in: cleanText, startingAt: searchStartIndex) {
                                let nsRange = NSRange(range, in: cleanText)
                                allWordTokens.append(WordToken(
                                    word: word,
                                    nsRange: nsRange,
                                    startTime: (mToken.start_ts ?? 0) + currentAudioTime,
                                    endTime: (mToken.end_ts ?? 0) + currentAudioTime
                                ))
                                searchStartIndex = range.upperBound
                            }
                        }
                    }
                    charsDone += chunk.count
                    currentAudioTime += Double(audio.count) / sampleRate
                }

                let timeElapsed = Date().timeIntervalSince(startTime)
                let progressValue = totalChars > 0 ? Float(charsDone) / Float(totalChars) : 0
                let remainingTime: TimeInterval?
                if charsDone > 0, timeElapsed > 0, charsDone < totalChars {
                    let charsPerSecond = Double(charsDone) / timeElapsed
                    remainingTime = Double(totalChars - charsDone) / charsPerSecond
                } else {
                    remainingTime = nil
                }

                await MainActor.run {
                    self.progress = progressValue
                    if let remainingTime {
                        self.estimatedTimeRemaining = remainingTime
                    }
                }
            }
        }.value

        // Check if temp file exists and has content
        if let attrs = try? fileManager.attributesOfItem(atPath: tempAudioURL.path),
           let size = attrs[.size] as? UInt64 {
            Self.log.info("📁 Temp CAF file size: \(size, privacy: .public) bytes")
            if size == 0 {
                throw NSError(domain: "TTSService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Temp audio file is empty"])
            }
        }

        // Convert temporary CAF to final M4A using AVAssetWriter for precise control
        Self.log.info("📦 Compressing audio to M4A (64kbps)...")
        try await convertToM4A(inputURL: tempAudioURL, outputURL: finalAudioURL)

        // Clean up temp file
        try? fileManager.removeItem(at: tempAudioURL)

        // Update entry
        entry.audioFileURL = finalAudioURL
        let encoder = JSONEncoder()
        if let encodedTokens = try? encoder.encode(allWordTokens) {
            entry.tokens = encodedTokens
        }
        // Sync metadata. fileSize and bodyHash are cheap; audioHash is computed off-main.
        if let attrs = try? fileManager.attributesOfItem(atPath: finalAudioURL.path) {
            entry.fileSize = attrs[.size] as? Int64
        }
        entry.bodyHash = FileHashing.sha256(string: entry.body)
        entry.markAsUpdated()

        // Audio SHA-256 streams a large file — push to background to avoid blocking UI
        let audioURLForHash = finalAudioURL
        let entryID = entry.id
        Task.detached(priority: .utility) {
            guard let hash = try? FileHashing.sha256(url: audioURLForHash) else { return }
            await MainActor.run {
                entry.audioHash = hash
                _ = entryID
            }
        }

        await MainActor.run {
            self.isGenerating = false
            self.progress = 1.0
            self.estimatedTimeRemaining = nil
        }

        // Memory Optimization: Clear GPU cache immediately after generation
        GPU.clearCache()

        // Start/Reset inactivity timer to unload weights after 2 minutes
        scheduleUnload()
    }

    nonisolated private static func findRange(for word: String, in text: String, startingAt index: String.Index) -> Range<String.Index>? {
        // 1. Try direct match first (fastest)
        if let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: index..<text.endIndex) {
            return range
        }

        // 2. Try regex-based matching to account for smart quotes and hyphens
        let escapedWord = NSRegularExpression.escapedPattern(for: word)
        let pattern = escapedWord
            .replacingOccurrences(of: "'", with: "['’‘]")
            .replacingOccurrences(of: "\"", with: "[\"“”«»]")
            .replacingOccurrences(of: " ", with: "[\\s\\-]")

        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let searchRange = NSRange(index..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: searchRange) {
                return Range(match.range, in: text)
            }
        }

        return nil
    }

    private func convertToM4A(inputURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "TTSService", code: 3, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }

        // 64kbps is excellent for 24kHz mono speech
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        // Explicitly request 16-bit Integer PCM (more compatible with AAC encoder than Float32)
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        reader.add(readerOutput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Use nonisolated(unsafe) to silence warnings for capture in the @Sendable closure.
        nonisolated(unsafe) let unsafeWriter = writer
        nonisolated(unsafe) let unsafeWriterInput = writerInput
        nonisolated(unsafe) let unsafeReaderOutput = readerOutput

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            unsafeWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.convert")) {
                while unsafeWriterInput.isReadyForMoreMediaData {
                    if let buffer = unsafeReaderOutput.copyNextSampleBuffer() {
                        unsafeWriterInput.append(buffer)
                    } else {
                        unsafeWriterInput.markAsFinished()
                        unsafeWriter.finishWriting {
                            if unsafeWriter.status == .failed {
                                let error = unsafeWriter.error ?? NSError(domain: "TTSService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Write failed"])
                                Self.log.error("❌ AVAssetWriter failed: \(error.localizedDescription, privacy: .public)")
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            let error = reader.error ?? NSError(domain: "TTSService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Read failed"])
            Self.log.error("❌ AVAssetReader failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 1 minute
            if !Task.isCancelled {
                await unloadEngine()
            }
        }
    }

    func unloadEngine() async {
        guard isReady && !isGenerating else { return }

        Self.log.info("🧹 Inactivity timeout: Unloading TTS Engine to free memory...")
        kokoro = nil
        voices = [:]
        isReady = false
        initializationTask = nil
        GPU.clearCache()
    }

    private func splitIntoChunks(_ text: String, speed: Float) -> [String] {
        // Dynamic chunk size based on speed. Slower speed = longer audio = more memory.
        let baseSize = UserDefaults.standard.object(forKey: "ttsBaseChunkSize") as? Int ?? 300
        let calculatedLimit = Int(Float(baseSize) * speed)

        // We cap the effective limit to a reasonable maximum to avoid exceeding the model's 510-token limit.
        // 500 characters is a safe upper bound for most sentences.
        let effectiveLimit = min(500, max(50, calculatedLimit))

        // Split by sentences OR newlines
        let pattern = "(?<=[.!?])\\s+|\\n+"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)

        var sentences: [String] = []
        var lastEnd = text.startIndex

        if let matches = regex?.matches(in: text, range: range) {
            for match in matches {
                if let matchRange = Range(match.range, in: text) {
                    let sentence = String(text[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty {
                        sentences.append(sentence)
                    }
                    lastEnd = matchRange.upperBound
                }
            }
        }

        let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        // Group sentences into chunks using the dynamic limit
        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            if (currentChunk.count + sentence.count) < effectiveLimit {
                currentChunk += (currentChunk.isEmpty ? "" : " ") + sentence
            } else {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                }
                currentChunk = sentence
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    func saveAudio(samples: [Float], to url: URL) throws {
        let sampleRate = 24000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity

        for i in 0..<samples.count {
            buffer.floatChannelData![0][i] = samples[i]
        }

        try audioFile.write(from: buffer)
    }

    private func normalizeText(_ text: String) -> String {
        var normalized = text

        // 1. Replace smart quotes with straight ones
        let replacements = [
            "“": "\"", "”": "\"",
            "‘": "'", "’": "'",
            "«": "\"", "»": "\""
        ]

        for (target, replacement) in replacements {
            normalized = normalized.replacingOccurrences(of: target, with: replacement)
        }

        // 2. Ensure spacing after punctuation if it's followed by a letter
        let punctuationRegex = try? NSRegularExpression(pattern: "([.!?])(\\w)", options: [])
        normalized = punctuationRegex?.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: "$1 $2"
        ) ?? normalized

        // 3. Remove hyphens from compound words (e.g., "living-room" -> "living room") to improve TTS
        let hyphenPattern = "(?<=\\p{L})-(?=\\p{L})"
        let hyphenRegex = try? NSRegularExpression(pattern: hyphenPattern, options: [])
        normalized = hyphenRegex?.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: " "
        ) ?? normalized

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WordToken {
    // Helper to check if a range intersects with another (useful for tap detection later)
    func intersects(_ other: NSRange) -> Bool {
        NSIntersectionRange(nsRange, other).length > 0
    }
}
