# WhisperSwiftKey

Native macOS speech-to-text keyboard input using [WhisperKit](https://github.com/argmaxinc/WhisperKit) — 100% on-device, zero cloud dependency.

## Download

[**Download WhisperSwiftKey 0.1.2 for macOS**](https://github.com/laanlabs/WhisperSwiftKey/releases/download/v0.1.2/WhisperSwiftKey-0.1.2.zip)

Version 0.1.2 is signed with a Developer ID certificate, notarized by Apple,
and includes a stapled notarization ticket. WhisperSwiftKey is distributed
directly because the cross-application Accessibility APIs it needs are not
available to Mac App Store sandboxed apps.

## Features

- Double-tap Fn/Globe to start and stop dictation at the active text cursor
- Real-time transcription preview while speaking
- Floating microphone feedback near the caret and a stable transcript panel
- Push-to-talk and tap-to-toggle modes
- Multiple on-device Whisper models with automatic language detection
- Local transcription history and custom vocabulary
- Completely on-device transcription after the selected model is downloaded

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)
- Microphone permission
- Accessibility permission (for text insertion)
- Internet access for the initial Whisper model download

## Install and use

1. Download and unzip `WhisperSwiftKey-0.1.2.zip`.
2. Move `WhisperSwiftKey.app` to `/Applications` before opening it.
3. Open the app and complete its onboarding steps.
4. Grant Microphone and Accessibility access when prompted.
5. Choose and download a Whisper model.
6. Place the text cursor in any editable field, then double-tap Fn/Globe to
   start dictating. Double-tap again to stop.

WhisperSwiftKey is a menu bar app and does not appear in the Dock. If Fn/Globe
does not activate dictation, check **System Settings → Keyboard** for a macOS
shortcut that is already using that key.

## Building

Requires Xcode 15 or later.

1. Open `WhisperSwiftKey.xcodeproj` in Xcode
2. Select your signing team
3. Build & Run (⌘R)

## Direct distribution

WhisperSwiftKey is distributed outside the Mac App Store because its core
cross-application text insertion and cursor tracking use macOS Accessibility
APIs that are unavailable to an App Sandbox process.

To create a notarized release:

1. Install a **Developer ID Application** certificate for the signing team in
   Xcode's Accounts settings.
2. Select **Product → Archive** using the Release configuration.
3. In Organizer, select **Distribute App → Direct Distribution**.
4. Let Xcode sign with Developer ID, upload for notarization, and export the
   notarized app.

Release builds enable Hardened Runtime for notarization. App Sandbox remains
disabled intentionally.

## Architecture

- **SwiftUI** menu bar app (no dock icon)
- **WhisperKit** for on-device speech recognition
- **SwiftData** for transcription history
- **CGEvent** tap for global hotkey detection
- **Accessibility API** for text insertion at cursor

## License

MIT
