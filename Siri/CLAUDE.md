# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an iOS multimedia application called "Siri" that provides speech recognition, picture-in-picture display, and system audio recording capabilities. The project uses Tuist for project configuration and management.

## Build Commands

```bash
# Generate Xcode project (must be run after any Project.swift changes)
tuist generate

# Build the project
xcodebuild -workspace Siri.xcworkspace -scheme Siri -configuration Debug build

# Build for simulator (REQUIRED after code changes to verify correctness)
xcodebuild -workspace Siri.xcworkspace -scheme Siri -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for device
xcodebuild -workspace Siri.xcworkspace -scheme Siri -configuration Release -sdk iphoneos build

# Run tests
xcodebuild -workspace Siri.xcworkspace -scheme SiriTests -configuration Debug test

# Clean build
tuist clean
```

**Important**: After making any code changes, you MUST run the simulator build command to verify your changes compile correctly:
```bash
xcodebuild -workspace Siri.xcworkspace -scheme Siri -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## Architecture Overview

### Project Structure
The application consists of three main targets configured in `Project.swift`:

1. **Main App (Siri)**: SwiftUI-based iOS application
   - Bundle ID: `dev.tuist.Siri`
   - Entry point: `SiriApp.swift`

2. **Screen Broadcast Extension**: System extension for capturing audio
   - Bundle ID: `dev.tuist.Siri.ScreenBroadcastExtension`
   - Principal class: `ScreenBroadcastHandler`

3. **Unit Tests (SiriTests)**: Test target for the main app

### Core Components

#### Speech Recognition System
- **SpeechRecognitionManager**: Manages iOS Speech framework for Chinese speech-to-text conversion
- Uses `AVAudioEngine` for audio capture and `SFSpeechRecognizer` for recognition
- Audio session configured with `.playAndRecord` mode to support simultaneous recording and playback

#### Picture-in-Picture (PiP) System
- **PictureInPictureManager**: Creates and manages PiP windows
- **PictureInPictureTextView**: Custom overlay view for displaying text on PiP window
- **VideoGenerator**: Creates placeholder H.264 videos required for PiP functionality
- Uses private API to hide playback controls and detect PiP window creation

#### Screen Recording & Audio Capture
- **ScreenBroadcastHandler**: ReplayKit extension that captures system audio
- **ScreenBroadcastManager**: Main app controller for broadcast management
- **AudioFileManager**: Handles audio file storage and retrieval
- Audio saved as M4A files (AAC codec, 44.1kHz, stereo, 128kbps)

### Inter-Process Communication
The main app and broadcast extension communicate through App Group (`group.dev.tuist.Siri`) using JSON files:
- `broadcast_status.json`: Broadcasting state updates
- `audio_data.json`: Real-time audio level data
- `audio_notification.json`: Audio file creation/completion events
- `stop_command.json`: Stop broadcast command from main app

### Permission Requirements
The app requires these permissions (configured in Info.plist):
- **NSMicrophoneUsageDescription**: Microphone access for speech recording
- **NSSpeechRecognitionUsageDescription**: Speech recognition services
- **NSScreenRecordingUsageDescription**: Screen recording for audio capture
- **UIBackgroundModes**: Audio and background processing
- **App Groups Entitlement**: For IPC between app and extension

### Key Technical Patterns

#### Audio Session Management
The app carefully manages `AVAudioSession` to coordinate between:
- Speech recognition (recording)
- PiP video playback
- System audio playback
Different components use different audio session categories to avoid conflicts.

#### PiP Window Detection
The app uses a sophisticated window detection mechanism:
1. Monitors `UIWindow.didBecomeVisibleNotification`
2. Filters for `PGHostedWindow` or windows with specific characteristics
3. Maintains a list of suspected windows for later filtering
4. Adds text overlay once PiP window is identified

#### Audio Data Flow
1. Broadcast extension captures `CMSampleBuffer` from system audio
2. Converts to M4A format using `AVAssetWriter`
3. Saves to shared App Group container
4. Main app monitors and loads recordings
5. Provides playback via `AVAudioPlayer`

## Development Notes

- Always run `tuist generate` after modifying `Project.swift`
- The broadcast extension runs in a separate process with limited memory
- PiP requires a valid video file; the app generates placeholder videos on demand
- Audio files are stored in `AudioRecordings` directory within the App Group container
- File names use timestamp format: `SystemAudio_HH-MM-SS.m4a`