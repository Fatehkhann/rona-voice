# Rona Voice

A single-window, native macOS voice companion. Speak or type, receive a streamed reply from Apple Intelligence, and hear it through the supplied voice models. No account, settings screen, Python process, localhost server, or cloud API.

Replies use a casual spoken style, with occasional “hmm,” “um,” “I guess,” “aha,” acknowledgments, and light “ha”/“haha” reactions where appropriate. These are generated as spoken text, with no synthetic soundboard or bracketed stage directions. The supplied voice model determines the resulting prosody; it has no dedicated laughter/emotion control.

[Hear a conversational voice sample](docs/audio/conversational-sample.wav) · [View the app](docs/screenshots/rona-release-app.png) · [Validation results](docs/VALIDATION.md)

## Run

Build the app using the instructions below, then open **`build/Rona Voice.app`**. Click **Start talking**, allow microphone access, then speak. A pause sends your turn; Rona speaks its reply and listens again. **End conversation** or **Escape** releases the microphone and stops generation/playback. **Interrupt & speak** stops a reply and starts a new listening turn.

You can also type into the composer and press Return, choose one of the four included voices, mute replies, or start a new conversation with **⌘N**. **⌘⇧M** controls the microphone. Conversation content is kept in memory and cleared when the app exits or you select New.

## Requirements and offline behavior

- Apple silicon Mac, macOS 26 or later, with Apple Intelligence enabled and its model downloaded.
- English (United States) SpeechTranscriber assets installed by macOS before offline microphone use.
- Microphone permission for voice input; typed input does not require it.
- The supplied 174.5 MB (166.4 MiB) `YaraVoice_bundle` is included in this repository and embedded in the app.

The app uses `SystemLanguageModel.default` (the on-device model), `SpeechAnalyzer`/`SpeechTranscriber`, and local ONNX inference. It has the App Sandbox microphone entitlement and **no network client or server entitlement**. It never downloads automatically or falls back to remote recognition. Initial Apple model provisioning and build dependency downloads require internet; conversations run locally afterward.

If Apple Intelligence is unavailable, the app displays the reason and a retry control. If voice assets fail to load, typed conversation remains available. If speech recognition assets are absent, an inline **Download English** button explicitly starts a one-time download through Apple’s system `AssetInventory` service. This needs internet; it does not send conversation data. Availability is checked again when the app becomes active.

## Build

Requires Xcode with the macOS 26+ SDK, CMake, and XcodeGen. Development dependencies are isolated under `.build/deps`; no Python dependencies are installed.

```sh
git clone https://github.com/Fatehkhann/rona-voice.git
cd rona-voice
bash Scripts/build.sh
open "build/Rona Voice.app"
```

The first build downloads pinned ONNX Runtime 1.23.2, SentencePiece 0.2.1, and nlohmann/json 3.12.0 from their upstream repositories and verifies their SHA-256 hashes. SentencePiece is linked statically; ONNX Runtime is embedded in the app. Subsequent builds can run offline. Open `RonaVoice.xcodeproj` after generation to work in Xcode. `project.yml` is the project source of truth.

The output is ad-hoc signed to run locally and uses App Sandbox. Hardened runtime is disabled for this local build because ad-hoc signatures have no Team ID to validate an embedded dynamic library. For distribution, sign the app and embedded ONNX library with the same Developer ID, set `ENABLE_HARDENED_RUNTIME=YES`, notarize, and run a release validation pass. No developer account is configured by this project.

## Verify

```sh
# Reference tokenizer vectors, all four voices, PCM validity, and cancellation.
bash Scripts/test-native.sh

# macOS unit, real model integration, and UI tests.
xcodegen generate
xcodebuild -project RonaVoice.xcodeproj -scheme RonaVoice \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode test
```

macOS may require local authentication to enable XCTest UI Automation. Integration tests use the real installed Apple models; they skip explicitly if required models are unavailable. UI tests launch the actual app. This is a native macOS target, so an iOS Simulator is not applicable. See `docs/VALIDATION.md` for results and verification limits.

## Implementation

- `Conversation.swift`: observable turn state, pause-to-send, interruption, bounded input, and session lifecycle.
- `LanguageEngine.swift`: streamed Apple Foundation Models, recent-turn retention, and context rollover. The model has a bounded context; it is not a permanent memory or a tool-using agent.
- `SpeechInput.swift`: on-device transcription with format conversion, bounded audio input, and microphone cleanup.
- `VoiceRuntime.swift` and `Native/RonaSpeech.cpp`: serial native ONNX execution, SentencePiece tokenizer parity, per-voice cache, incremental 24 kHz PCM, and atomic cancellation.
- `AudioPlayback.swift`: queued native audio playback and cancellation-aware completion.
- `ConversationView.swift`: accessible SwiftUI interface, light/dark appearance, Reduce Motion support, keyboard controls, and selectable transcript.

Voice turns are half-duplex: microphone capture stops during playback to prevent echo. Use **Interrupt & speak** for a new turn while Rona is speaking. Automatic acoustic barge-in, diarization, background listening, persistent transcripts, external tools, and multilingual voices are outside this version.

Model attribution, licenses, original bundle metadata, and dependency notices are included in `Resources/ThirdPartyNotices.txt`, `Resources/Legal`, and the app’s **Third-Party Notices** menu item. Original model files and the supplied Python reference are unchanged.
