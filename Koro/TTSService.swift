import Foundation
@preconcurrency import AVFoundation
import KokoroSwift
import MLX
import SwiftData
import Combine
import MLXUtilsLibrary

@MainActor
final class TTSService: ObservableObject {
    nonisolated(unsafe) private var kokoro: KokoroTTS?
    nonisolated(unsafe) private var voices: [String: MLXArray] = [:]
    private var initializationTask: Task<Void, Never>?

    @Published var isGenerating = false
    @Published var isReady = false
    @Published var progress: Float = 0.0
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
        // Start initial prep
        Task {
            await prepareEngine()
        }
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

        print("🚀 Starting TTS Engine initialization...")

        guard let modelURL = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors") else {
            print("❌ Critical: kokoro-v1_0.safetensors not found in bundle.")
            return
        }

        guard let voicesURL = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            print("❌ Critical: voices.npz not found in bundle.")
            return
        }

        let result = await Task.detached(priority: .userInitiated) { () -> InitializationResult in
            print("📦 Loading model weights...")
            let kokoro = KokoroTTS(modelPath: modelURL)
            print("🗣️ Loading voices...")
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
        print("✅ TTS Engine Ready with \(self.voices.count) voices.")
    }

    func generateAudio(for entry: Entry, voiceName: String, speed: Float) async throws {
        // Ensure engine is ready before starting
        if !isReady {
            await prepareEngine()
        }

        guard let kokoro = kokoro else {
            print("❌ Cannot generate audio: Engine not initialized")
            return
        }

        let fullVoiceName = voiceName.hasSuffix(".npy") ? voiceName : "\(voiceName).npy"
        guard let voiceArray = voices[fullVoiceName] else {
            print("❌ Voice \(voiceName) not found")
            return
        }

        isGenerating = true
        progress = 0.0

        let rawText = entry.body
        let text = normalizeText(rawText)

        let chunks = splitIntoChunks(text, speed: speed)
        print("📝 Split text into \(chunks.count) chunks (speed: \(speed))")

        // Detect language based on voice ID prefix
        // a = American (enUS), b = British (enGB)
        let lang: Language = fullVoiceName.hasPrefix("b") ? .enGB : .enUS
        print("🌐 Using language: \(lang == .enGB ? "British" : "American")")

        var allWordTokens: [WordToken] = []
        var currentAudioTime: Double = 0
        var searchStartIndex = rawText.startIndex

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
        try await Task.detached(priority: .userInitiated) { [rawText, voiceArray, lang, kokoro] in
            let audioFile = try AVAudioFile(forWriting: tempAudioURL, settings: format.settings)

            for (index, chunk) in chunks.enumerated() {
                await MainActor.run {
                    self.progress = Float(index) / Float(chunks.count)
                }

                try autoreleasepool {
                    print("🔄 Starting chunk \(index + 1)/\(chunks.count) (length: \(chunk.count) chars)")
                    let (audio, mTokens) = try kokoro.generateAudio(voice: voiceArray, language: lang, text: chunk, speed: speed)

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

                            if let range = TTSService.findRange(for: word, in: rawText, startingAt: searchStartIndex) {
                                let nsRange = NSRange(range, in: rawText)
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
                    currentAudioTime += Double(audio.count) / sampleRate
                }
            }
        }.value

        // Check if temp file exists and has content
        if let attrs = try? fileManager.attributesOfItem(atPath: tempAudioURL.path),
           let size = attrs[.size] as? UInt64 {
            print("📁 Temp CAF file size: \(size) bytes")
            if size == 0 {
                throw NSError(domain: "TTSService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Temp audio file is empty"])
            }
        }

        // Convert temporary CAF to final M4A using AVAssetWriter for precise control
        print("📦 Compressing audio to M4A (64kbps)...")
        try await convertToM4A(inputURL: tempAudioURL, outputURL: finalAudioURL)

        // Clean up temp file
        try? fileManager.removeItem(at: tempAudioURL)

        // Update entry
        entry.audioFileURL = finalAudioURL
        let encoder = JSONEncoder()
        if let encodedTokens = try? encoder.encode(allWordTokens) {
            entry.tokens = encodedTokens
        }
        // Sync metadata
        entry.audioHash = (try? FileHashing.sha256(url: finalAudioURL))
        if let attrs = try? fileManager.attributesOfItem(atPath: finalAudioURL.path) {
            entry.fileSize = attrs[.size] as? Int64
        }
        entry.markAsUpdated()

        progress = 1.0
        isGenerating = false

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
                                print("❌ AVAssetWriter failed: \(error)")
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
            print("❌ AVAssetReader failed: \(error)")
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

        print("🧹 Inactivity timeout: Unloading TTS Engine to free memory...")
        kokoro = nil
        voices = [:]
        isReady = false
        initializationTask = nil
        GPU.clearCache()
    }

    private func splitIntoChunks(_ text: String, speed: Float) -> [String] {
        // Dynamic chunk size based on speed. Slower speed = longer audio = more memory.
        let baseSize = UserDefaults.standard.object(forKey: "ttsBaseChunkSize") as? Int ?? 400
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
