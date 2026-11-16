// swift-tools-version: 6.0
//
// MODIFIED COPY of FluidAudio (https://github.com/FluidInference/FluidAudio,
// Apache License 2.0; upstream commit in UPSTREAM_COMMIT). Changed for
// Jarvis, 16/11/2026, so it installs in Swift Playgrounds on an iPad, which
// can only build pure-Swift targets:
//   - removed the prebuilt NemoTextProcessing binary target (FluidAudio's own
//     opt-out: TTS text then passes through unchanged),
//   - removed the C/C++ FastClusterWrapper and MachTaskSelfWrapper targets and
//     the "Diarizer" subsystem that needs them (FluidAudio's own opt-out),
//   - excluded the ASR, VAD, Diarizer, Enhancement, Speaker, Decision and
//     TTS/LFM3Audio folders from the build, with JarvisTrimStubs.swift standing
//     in for the five small types ModelNames.swift still names (1.1.0),
//   - removed the LuxTtsG2pResources target (only the LuxTTS engine uses it,
//     behind canImport), the command-line tool and the tests.
// The library's Swift source is otherwise unchanged.
import PackageDescription

let package = Package(
    name: "FluidAudio",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "FluidAudio",
            targets: ["FluidAudio"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FluidAudio",
            path: "Sources/FluidAudio",
            exclude: [
                // Not used by Jarvis (text-to-speech only); left out so Swift
                // Playgrounds builds faster. See JarvisTrimStubs.swift.
                "ASR", "VAD", "Diarizer", "Enhancement", "Speaker", "Decision", "TTS/LFM3Audio",
            ],
            swiftSettings: [
                .define("TTS")
            ]
        )
    ]
)
