# jarvis-fable-voice

A trimmed, pure-Swift copy of [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference, used to give a personal assistant app the Kokoro "Fable" voice on an iPad running Swift Playgrounds.

Swift Playgrounds on iPad can only build pure-Swift packages, so this copy removes the parts it can't handle. Each was already optional in FluidAudio itself:

- the prebuilt NeMo text-normalisation engine (text now passes through unchanged),
- the C/C++ helper targets and the speaker-diarisation features that need them,
- the LuxTTS resource bundle, the command-line tool and the tests.
- from 1.1.0, the speech-recognition, voice-activity, diarisation, speech-enhancement and speaker folders and the LFM3Audio engine are left out of the build (faster builds in Swift Playgrounds); `Sources/FluidAudio/JarvisTrimStubs.swift` holds verbatim copies of the five small settings types `ModelNames.swift` still names, and one ASR-only helper was removed from `ITN/TextNormalizer.swift`.

The library's Swift source is otherwise unchanged, apart from two small, marked changes so the removed pieces don't break the build: a guard in `Sources/FluidAudio/TTS/LuxTts/G2p/LuxTtsG2p.swift`, and a stand-in for the removed memory-reporting helper in `Sources/FluidAudio/Shared/SystemInfo.swift` (memory figures now report as unavailable). The upstream commit it was taken from is in `UPSTREAM_COMMIT`.

## Jarvis app file

**[FableVoice for the iPad: tap here for the latest version](https://github.com/ravenshoegunclub/jarvis-fable-voice/blob/60bbf7f/JarvisApp/FableVoice.swift)**

This link is fixed to an exact version, so it is never out of date.

## Licence

FluidAudio is licensed under the Apache License 2.0 (see `LICENSE` and `ThirdPartyLicenses/`). All credit for the library goes to FluidInference and its contributors. The changes made here are listed above and at the top of `Package.swift`.
