// jarvis-fable-voice change (16/11/2026): the ASR, VAD, Diarizer, Enhancement,
// Speaker and Decision folders and TTS/LFM3Audio are excluded from the build
// (Package.swift) so Swift Playgrounds builds faster. ModelNames.swift still
// names these few small settings types from them, so verbatim copies live here:
// CanaryPrecision (ASR/Canary/CanaryConfig.swift), LocalVqeVariant / LocalVqeChunk
// (Enhancement/LocalVQE/LocalVqeTypes.swift, minus samplesPerCall, which needs the
// excluded LocalVqeManager), and UnifiedEncoderPrecision / NemotronUnifiedLanguage /
// UnifiedModelFamily (ASR/Parakeet/Unified/UnifiedConfig.swift).
@preconcurrency import CoreML
import Foundation

/// Canary encoder/decoder weight precision.
///
/// `int4` (per-block-32 symmetric) runs on the Neural Engine and is the
/// smallest build (~573 MB) — but int4 weight payloads require iOS18 / macOS 15.
/// `fp16` is the iOS17 parity fallback (exact match to PyTorch). `int8`
/// (per-channel) decodes correctly only on CPU — it crashes the GPU/ANE MPSGraph
/// backend — so it is a CPU/size-only option.
public enum CanaryPrecision: String, Sendable, CaseIterable {
    case int4
    case fp16
    case int8

    var encoderName: String {
        switch self {
        case .int4: return ModelNames.Canary.encoderInt4
        case .fp16: return ModelNames.Canary.encoder
        case .int8: return ModelNames.Canary.encoderInt8
        }
    }

    var decoderName: String {
        switch self {
        case .int4: return ModelNames.Canary.decoderInt4
        case .fp16: return ModelNames.Canary.decoder
        case .int8: return ModelNames.Canary.decoderInt8
        }
    }

    /// int8 only decodes correctly on CPU; int4/fp16 run on the Neural Engine.
    var computeUnits: MLComputeUnits {
        self == .int8 ? .cpuOnly : .cpuAndNeuralEngine
    }
}

/// Which LocalVQE checkpoint to run.
///
/// Both are joint acoustic-echo-cancellation + noise-suppression +
/// dereverberation models from [localai-org/LocalVQE](https://github.com/localai-org/LocalVQE)
/// (Apache-2.0). Every variant needs a far-end **reference** signal (what the
/// loudspeaker played) alongside the microphone signal.
public enum LocalVqeVariant: String, CaseIterable, Sendable {
    /// v1.3, 4.8M params. Best joint quality; upstream default.
    case v13 = "v1.3"
    /// v1.2, 1.3M params. ~1/4 the per-hop cost of v1.3 for tight CPU budgets.
    case v12 = "v1.2"

    var fileStem: String {
        switch self {
        case .v13: return "localvqe-v1.3-4.8M"
        case .v12: return "localvqe-v1.2-1.3M"
        }
    }
}

/// How many 16 ms hops each Core ML call consumes.
///
/// The model is causal either way and produces bit-identical audio; the chunk
/// size only trades per-call overhead against latency.
public enum LocalVqeChunk: String, CaseIterable, Sendable {
    /// One 256-sample hop per call (16 ms). Use for live capture.
    case realtime16ms = "16ms"
    /// Sixteen hops per call (256 ms). ~2.5x the throughput of `realtime16ms`; use for files.
    case batch256ms = "256ms"

    /// Number of 256-sample hops consumed per call.
    public var framesPerCall: Int {
        switch self {
        case .realtime16ms: return 1
        case .batch256ms: return 16
        }
    }

}

/// Encoder weight precision for Parakeet Unified 0.6B.
///
/// int8 (per-channel linear symmetric) is the default: identical LibriSpeech
/// test-clean WER to fp16 (offline 1.83% vs 1.82%, streaming 2.14% vs 2.15%),
/// identical ANE latency on M-series, and half the download/disk (~565 MB vs
/// ~1.1 GB per encoder).
public enum UnifiedEncoderPrecision: String, Sendable, CaseIterable {
    case int8
    case fp16
}

/// Language prompt for `nvidia/nemotron-labs-unified-asr-0.6b` (25 European languages + `auto`).
///
/// The multilingual checkpoint applies a language-ID prompt after the encoder; the CoreML encoders take it as an
/// int32 `prompt_id` input. Ids come from the checkpoint's `prompt_dictionary` (also in the HF repo's
/// `coreml/metadata.json`). For low-latency streaming NVIDIA recommends passing the language explicitly.
public enum NemotronUnifiedLanguage: String, Sendable, CaseIterable {
    case auto
    case bg, cs, da, de, el, en, es, et, fi, fr, hr, hu, it, lt, lv, mt, nl, pl, pt, ro, ru, sk, sl, sv, uk

    public var promptId: Int {
        switch self {
        case .auto: return 127
        case .en: return 0
        case .es: return 3
        case .fr: return 8
        case .de: return 9
        case .ru: return 11
        case .pt: return 13
        case .it: return 15
        case .nl: return 16
        case .pl: return 17
        case .uk: return 19
        case .ro: return 20
        case .el: return 21
        case .cs: return 22
        case .hu: return 23
        case .sv: return 24
        case .da: return 25
        case .fi: return 26
        case .sk: return 28
        case .hr: return 29
        case .bg: return 30
        case .lt: return 31
        case .et: return 60
        case .lv: return 61
        case .sl: return 62
        case .mt: return 102
        }
    }
}

/// Which Unified FastConformer-RNNT checkpoint the Unified managers run.
///
/// - `parakeetEnglish`: `nvidia/parakeet-unified-en-0.6b` (English, 1024 tokens + blank).
/// - `nemotronMultilingual`: `nvidia/nemotron-labs-unified-asr-0.6b` (25 European languages, 4095 tokens + blank,
///   language prompt fed to the encoder as `prompt_id`).
///
/// Both share the encoder layout, mel front end, decoder/joint contract and streaming contexts; the family picks
/// the HF repo, bundle names, blank index and prompt.
public enum UnifiedModelFamily: Sendable, Equatable {
    case parakeetEnglish
    case nemotronMultilingual(NemotronUnifiedLanguage)

    public var repo: Repo {
        switch self {
        case .parakeetEnglish: return .parakeetUnified
        case .nemotronMultilingual: return .nemotronUnified
        }
    }

    /// Blank token id (= vocabulary size).
    public var blankIdx: Int {
        switch self {
        case .parakeetEnglish: return 1024
        case .nemotronMultilingual: return 4095
        }
    }

    /// Encoder `prompt_id` input, or nil for the English checkpoint (no prompt input).
    public var promptId: Int? {
        switch self {
        case .parakeetEnglish: return nil
        case .nemotronMultilingual(let language): return language.promptId
        }
    }

    public var displayName: String {
        switch self {
        case .parakeetEnglish: return "Parakeet Unified 0.6B"
        case .nemotronMultilingual(let language): return "Nemotron Unified ASR 0.6B (\(language.rawValue))"
        }
    }

    var filePrefix: String {
        switch self {
        case .parakeetEnglish: return "parakeet_unified"
        case .nemotronMultilingual: return "nemotron_unified"
        }
    }

    public func streamingEncoderFile(precision: UnifiedEncoderPrecision, contextSuffix: String) -> String {
        let base = "\(filePrefix)_encoder_streaming_\(contextSuffix)"
        return precision == .int8 ? "\(base)_int8.mlmodelc" : "\(base).mlmodelc"
    }

    public func offlineEncoderFile(precision: UnifiedEncoderPrecision) -> String {
        precision == .int8 ? "\(filePrefix)_encoder_int8.mlmodelc" : "\(filePrefix)_encoder.mlmodelc"
    }

    public var decoderFile: String { "\(filePrefix)_decoder.mlmodelc" }
    public var jointDecisionFile: String { "\(filePrefix)_joint_decision_single_step.mlmodelc" }
    public var vocab: String { "vocab.json" }
    public var metadata: String { "metadata.json" }
}
