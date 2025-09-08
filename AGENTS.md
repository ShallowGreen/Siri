# AGENTS.md

Guidance for AI coding agents working in this repository. Follow these rules to stay aligned with the project and keep changes safe, focused, and verifiable.

## Scope & Precedence
- Scope: applies to the entire repository unless a more deeply nested AGENTS.md overrides specifics.
- Precedence: direct user/developer instructions override this file. Deeper AGENTS.md files take precedence over this one.

## Quick Start (Build/Test)
- Generate workspace (after `Project.swift` changes): `tuist generate`
- Open in Xcode: `open Siri/Siri.xcworkspace`
- Build app (Debug): `xcodebuild -workspace Siri/Siri.xcworkspace -scheme Siri -configuration Debug build`
- Build for Simulator (sanity check after code changes): `xcodebuild -workspace Siri/Siri.xcworkspace -scheme Siri -destination 'platform=iOS Simulator,name=iPhone 16' build`
- Run tests: `xcodebuild -workspace Siri/Siri.xcworkspace -scheme Siri -destination 'platform=iOS Simulator,name=iPhone 16' test`
- Clean Tuist cache: `tuist clean`

Important: After making code changes, prefer the Simulator build command above to verify compilation for iOS.

## Project Structure & Modules
- `Siri/` — Xcode project and Tuist config.
  - `Siri/Sources/` — app code (SwiftUI views, managers, PiP, audio, speech).
  - `Siri/Resources/` — app assets.
  - `Siri/Tests/` — XCTest files (e.g., `SiriTests.swift`).
- `ScreenBroadcastExtension/` — ReplayKit broadcast extension sources.
- `Project.swift`, `Tuist.swift` — Tuist project definition.
- `Siri/Siri.xcodeproj`, `Siri/Siri.xcworkspace` — generated Xcode artifacts.

## Architecture Overview
- Targets (configured in `Siri/Project.swift`):
  - Main App (Siri) — SwiftUI iOS app, entry `SiriApp.swift`.
  - Screen Broadcast Extension — ReplayKit extension (`ScreenBroadcastHandler`).
  - Unit Tests (`Siri/Tests`).

- Core components:
  - SpeechRecognitionManager — iOS Speech framework via `AVAudioEngine` + `SFSpeechRecognizer`.
  - PictureInPictureManager / PictureInPictureTextView — PiP creation and overlay text.
  - VideoGenerator — placeholder H.264 video required for PiP.
  - ScreenBroadcastManager — controls broadcast lifecycle in the app.
  - ScreenBroadcastHandler — ReplayKit extension capturing system audio.
  - AudioFileManager — audio storage and retrieval (M4A/AAC, 44.1kHz, stereo).

- Inter‑process communication (App Group `group.dev.tuist2.Siri`):
  - `broadcast_status.json` — broadcasting state updates.
  - `audio_data.json` — real‑time audio level data.
  - `audio_notification.json` — audio file creation/completion events.
  - `stop_command.json` — stop broadcast command from main app.

- Permissions (Info.plist / entitlements):
  - NSMicrophoneUsageDescription
  - NSSpeechRecognitionUsageDescription
  - NSScreenRecordingUsageDescription
  - UIBackgroundModes (audio, background processing)
  - App Groups entitlement (shared container with extension)

## Coding Style & Naming
- Use Swift 4‑space indentation; follow Swift API Design Guidelines.
- Types/protocols: UpperCamelCase (e.g., `ScreenBroadcastManager`).
- Methods/vars: lowerCamelCase (e.g., `startRecording()`).
- One primary type per file; filename matches type (e.g., `PictureInPictureController.swift`).
- SwiftUI views end with `View`; managers end with `Manager`.

## Testing Guidelines
- Framework: XCTest under `Siri/Tests`.
- Name tests descriptively: `FeatureNameTests`; methods `test_condition_expectedResult`.
- Add tests for new logic (managers, conversions, IPC parsing). UI snapshot tests are optional.
- Run via Xcode or: `xcodebuild -workspace Siri/Siri.xcworkspace -scheme Siri -destination 'platform=iOS Simulator,name=iPhone 16' test`.

## Agent Workflow Expectations
- Plans: when a task spans multiple steps, use a concise plan and keep it updated as you progress.
- Preambles: before running grouped shell commands, briefly state what you’re about to do.
- Edits: use minimal, focused diffs; don’t change filenames or structure unless required by the task.
- Validation: after edits, prefer a Simulator build to confirm the code compiles; run tests when relevant.
- Don’t: introduce unrelated refactors, add licenses, change bundle IDs, or modify entitlements unless explicitly requested.
- Tuist: always run `tuist generate` after changing `Project.swift` or Tuist setup.

## Commit & PR Guidelines
- Commit prefixes: `feat:`, `fix:`, `chore:`, `refactor:`, `test:`, `docs:` — imperative, concise subjects.
- PRs include: clear description, rationale, before/after screenshots/recordings for UI changes, steps to test, and linked issues.
- Keep changes focused; update Tuist files (`Siri/Project.swift`) when structure changes.

## Security & Config Tips
- Speech server: update `serverURL` in `Siri/Sources/SpeechRecognitionManager.swift` for your environment.
- Entitlements: ReplayKit/microphone permissions and App Group IDs must match between app and extension.
- Avoid committing secrets; prefer per‑developer configs.

## Development Notes & Pitfalls
- The broadcast extension runs in a separate process with tighter memory constraints.
- PiP requires a valid video file; placeholder video is generated on demand by `VideoGenerator`.
- Audio files are stored in the App Group container under an `AudioRecordings` directory; filenames use timestamp patterns like `SystemAudio_HH-MM-SS.m4a`.
- Ensure workspace pathing: most commands target `Siri/Siri.xcworkspace` and scheme `Siri`.
