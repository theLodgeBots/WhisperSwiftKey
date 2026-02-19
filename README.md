# WhisperSwiftKey

Native macOS speech-to-text keyboard input using [WhisperKit](https://github.com/argmaxinc/WhisperKit) — 100% on-device, zero cloud dependency.

## Features (Planned)
- 🎤 Double-tap Fn to dictate, text appears at cursor
- 🔒 Completely on-device — no audio ever leaves your Mac
- ⚡ Optimized for Apple Silicon (M1/M2/M3/M4)
- 📖 Custom dictionary for names, jargon, technical terms
- 🎯 Push-to-talk and tap-to-toggle modes
- 🌍 58 language support with auto-detection
- 📊 Transcription history with search
- 🤖 Optional AI agent mode (local LLM post-processing)

## Requirements
- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)
- Xcode 15.0+
- Microphone permission
- Accessibility permission (for text insertion)

## Building
1. Open `WhisperSwiftKey.xcodeproj` in Xcode
2. Select your signing team
3. Build & Run (⌘R)

## Architecture
- **SwiftUI** menu bar app (no dock icon)
- **WhisperKit** for on-device speech recognition
- **SwiftData** for transcription history
- **CGEvent** tap for global hotkey detection
- **Accessibility API** for text insertion at cursor

## License
MIT
