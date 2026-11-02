# Local validation — 2 November 2026

Environment: Apple M4 Pro, 48 GB RAM, macOS 26.6.2 (25G83), Xcode 27.0. Apple Intelligence and English (US) speech assets were already installed. This is a native macOS app; no iOS Simulator was used.

## Rona rename verification

- Renamed the app, Xcode targets, interface labels, microphone permission descriptions, and conversational identity to **Rona Voice / Rona**. The original application identifier remains unchanged to preserve macOS permissions; supplied model filenames and attribution remain intact.
- Rebuilt `build/Rona Voice.app` and passed `codesign --verify --deep --strict`. Build log: `.build/rona-release-build.log`.
- All 5 unit and real-model integration tests passed without skips in `.build/rona-rename-tests.log`. The subsequent UI test run was stopped because the Mac's screen was locked and XCTest could not activate the app. This rename run does not establish new interactive UI coverage.
- A separate real Foundation Models check using the app's updated instructions answered “My name is Rona.” to “What is your name?” Evidence: `.build/rona-identity-check.txt`.
- Opened the packaged release and visually inspected its actual window capture, `screenshots/rona-release-app.png`, confirming the Rona header and unchanged layout. Interactive actions were not exercised while the Mac was locked.

## Initial validation before the rename

- Release app builds successfully and passes `codesign --verify --deep --strict` with local ad-hoc signing.
- All **7 XCTest tests passed**, with no skips: 4 state/text-stream tests, 1 real model integration test, and 2 OS-driven UI tests. Result bundle: `.build/FinalValidation.xcresult`; log: `.build/final-validation.log`.
- The integration test generated a real Apple Foundation Models response, synthesized it with the bundled warm voice, transcribed the resulting audio with Apple SpeechTranscriber, and verified conversational memory on a follow-up turn. See `offline-pipeline.txt`.
- UI tests launched the actual macOS app, entered and sent text, checked the real reply and remembered name, stopped active speech, cleared the conversation, toggled mute, opened the live microphone, and stopped it. Microphone permission was granted through macOS. Screenshots were captured by XCTest and visually inspected.
- The native C++ tests passed all 10 supplied tokenizer vectors, synthesis with all four personas, finite/non-silent PCM checks, cancellation before and during synthesis, invalid voice, empty text, and the conversational interjection/laughter-text sample. See `native-test-results.txt`.
- Apple's offline recognizer correctly recovered the greeting from all four generated persona samples. Local synthesis took approximately 0.36–0.65 seconds for 3.28–4.56 seconds of audio in the final native run; these are measurements on this Mac, not guarantees for other hardware.
- All supplied model and voice SHA-256 checksums still match. Original model assets and `pocket_onnx.py` are unchanged.

## Initial visual inspection before the rename

The `screenshots/ui-*` files are actual window screenshots from the passing UI tests: welcome, live microphone, microphone stopped, reply, remembered context, interruption, and cleared conversation. Checked readable text, visible controls, transcript wrapping, status changes, and the native window chrome.

`release-app.png` and `release-minimum-size.png` are window screenshots of the final packaged release. The 900 × 690 layout was resized through macOS and visually checked after fixing heading truncation.

The other screenshots are captures of the running app's content view made by a debug-only, in-process smoke test. These cover light/dark appearances and reply states. The smoke test also verified mute during playback, immediate new input after interruption, and playback completion. They are distinguished from OS-driven UI screenshots and do not establish microphone behavior. Results are in `in-app-test-results.json`.

During validation, a Swift 6 actor-isolation trap on the first microphone buffer was found and fixed by making the real-time tap callback explicitly `@Sendable`. The local release's initial hardened-runtime/ad-hoc-signing incompatibility was also fixed; see the signing notes in the README. These issues do not reproduce in the final passing checks.

## Boundaries

- Live microphone start/stop and actual audio-buffer processing were tested. A sustained human-spoken conversation in varied background noise, Bluetooth device switching, and long-duration microphone sessions were not tested.
- Speech recognition was verified with generated audio files. The Mac's network was not physically disconnected during testing. Conversation APIs explicitly use on-device models; the app has no network client/server entitlement. Only the explicit first-time **Download English** action asks Apple's system service to provision speech assets.
- The first-time speech download path, denied-permission recovery, unavailable Apple Intelligence hardware/regions, and fresh installation on another Mac were not exercised because this Mac already had the required models.
- “Hmm,” “um,” “aha,” “I guess,” and “haha” are generated spoken text. The bundled model does not expose a distinct emotional/laughter control. `audio/conversational-sample.wav` demonstrates the supplied model's rendering; no subjective naturalness score is claimed.
- This is a locally runnable build. Developer ID signing, hardened runtime under that identity, notarization, and distribution validation remain release steps.
