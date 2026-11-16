import AVFoundation
import Foundation
import FluidAudio

/* ============================================================
   FABLE VOICE · Jarvis's own voice, on this iPad, offline
   The same voice Home Jarvis speaks with on the laptop: Kokoro's
   British male voice "Fable" (bm_fable), Carl's choice 16/11/2026.
   Kokoro runs here through FluidAudio, from a trimmed pure-Swift copy
   Swift Playgrounds can build (github.com/ravenshoegunclub/
   jarvis-fable-voice).
     pronunciation → FluidAudio's Paradee frontend, British rules
                     (the full Kokoro engine only reads American ones)
     voice         → the full Kokoro-82M model, voice bm_fable,
                     speed 1.15 like the laptop
   Replaces the old ElevenLabs file (CloudVoice.swift) in the same slot,
   so JarvisCore and JarvisScreen are unchanged: they still ask
   CloudVoiceKey.isSet and CloudVoice.fetchAudio(text:). No key needed.
   The voice files download once on first launch; until they're ready,
   and on any failure, fetchAudio returns nil and Jarvis uses the iPad's
   own voice ("degrade, never mute").
   ============================================================ */

enum CloudVoiceKey {
    /// Always on: Fable needs no key. Asking also starts the one-off
    /// download and warm-up in the background.
    static var isSet: Bool {
        FableVoice.startWarmUp()
        return true
    }

    /// Kept so the old "Jarvis voice key" sheet still builds; Fable has no key.
    @discardableResult
    static func save(key: String, voiceID: String) -> Bool { true }
}

enum CloudVoice {
    /// WAV audio of `text` in Fable's voice, or nil if Fable isn't ready yet.
    static func fetchAudio(text: String) async -> Data? {
        await FableVoice.shared.speak(text)
    }
}

actor FableVoice {
    static let shared = FableVoice()

    private static let voiceName = "bm_fable"
    private static let speed: Float = 1.15

    private let pronouncer = ParadeeManager()
    private let kokoro = KokoroAneManager(defaultVoice: FableVoice.voiceName)
    private var ready = false
    private var warmUpTask: Task<Void, Never>?

    static func startWarmUp() {
        Task { await shared.warmUp() }
    }

    /// Downloads (first time only) and loads the voice and the British
    /// pronunciation rules. Safe to call repeatedly; a failed attempt is
    /// retried on the next call.
    func warmUp() {
        guard warmUpTask == nil else { return }
        warmUpTask = Task {
            let started = Date()
            print("[Fable] Preparing the Fable voice (version four).")
            do {
                try await kokoro.initialize(preloadVoices: [FableVoice.voiceName])
                print("[Fable] Kokoro voice loaded after \(Int(Date().timeIntervalSince(started))) s; loading British pronunciation...")
                // Paradee must load its own tables (vocab, British lexicon) before
                // it will pronounce anything: "not initialized" otherwise (16/11/2026).
                try await pronouncer.initialize(voices: [.bmFable])
                _ = try await pronouncer.phonemes(for: "Good evening, sir.", voice: .bmFable)
                ready = true
                print("[Fable] Ready after \(Int(Date().timeIntervalSince(started))) s.")
            } catch {
                await FableStatus.say("The Fable voice couldn't load. \(String(String(describing: error).prefix(160)))")
                warmUpTask = nil
            }
        }
    }

    func speak(_ text: String) async -> Data? {
        print("[Fable] Asked to speak: \(String(text.prefix(60)))")
        guard ready else {
            print("[Fable] Not ready yet, so this reply uses the iPad's own voice.")
            warmUp()
            return nil
        }
        do {
            var parts: [Data] = []
            for sentence in FableVoice.sentences(in: text) {
                let phonemes = try await pronouncer.phonemes(for: sentence, voice: .bmFable)
                if phonemes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                parts.append(try await kokoro.synthesizeFromPhonemes(
                    phonemes, voice: FableVoice.voiceName, speed: FableVoice.speed))
            }
            let audio = FableWAV.join(parts)
            print("[Fable] Spoke \(parts.count) sentence(s), \(audio?.count ?? 0) bytes.")
            return audio
        } catch {
            print("[Fable] Couldn't speak that line: \(error)")
            return nil
        }
    }

    /// One sentence at a time keeps each request well inside Kokoro's
    /// 512-token limit.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}

/// Joins several WAV files (same format) into one, so a multi-sentence
/// reply plays as a single clip.
enum FableWAV {
    static func join(_ wavs: [Data]) -> Data? {
        guard let first = wavs.first else { return nil }
        if wavs.count == 1 { return first }
        guard var header = split(first)?.header else { return nil }
        var samples = Data()
        for wav in wavs {
            guard let body = split(wav)?.body else { return nil }
            samples.append(body)
        }
        // RIFF size at bytes 4-7; the data chunk's size is the header's last 4 bytes.
        write(UInt32(header.count - 8 + samples.count), into: &header, at: 4)
        write(UInt32(samples.count), into: &header, at: header.count - 4)
        return header + samples
    }

    /// The bytes up to and including the "data" chunk's size field, and the samples after it.
    private static func split(_ wav: Data) -> (header: Data, body: Data)? {
        let bytes = [UInt8](wav)
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8) else { return nil }
        var index = 12
        while index + 8 <= bytes.count {
            let chunkID = Array(bytes[index..<(index + 4)])
            let size = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8
                | Int(bytes[index + 6]) << 16 | Int(bytes[index + 7]) << 24
            if chunkID == Array("data".utf8) {
                let end = min(bytes.count, index + 8 + size)
                return (Data(bytes[0..<(index + 8)]), Data(bytes[(index + 8)..<end]))
            }
            index += 8 + size + (size & 1)
        }
        return nil
    }

    private static func write(_ value: UInt32, into data: inout Data, at offset: Int) {
        let littleEndian = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        data.replaceSubrange(offset..<(offset + 4), with: littleEndian)
    }
}

/// Says aloud, in the iPad's own voice, if Fable fails to load, so a fault
/// can't hide behind the silent fall-back. Also printed to the console.
@MainActor
enum FableStatus {
    private static let synthesizer = AVSpeechSynthesizer()

    static func say(_ text: String) {
        print("[Fable] " + text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        synthesizer.speak(utterance)
    }
}
