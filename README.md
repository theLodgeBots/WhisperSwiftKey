# WhisperSwiftKey

Native macOS speech-to-text keyboard input using [WhisperKit](https://github.com/argmaxinc/WhisperKit) — 100% on-device, zero cloud dependency.

## Download

[**Download WhisperSwiftKey 0.2.0 for macOS**](https://github.com/laanlabs/WhisperSwiftKey/releases/download/v0.2.0/WhisperSwiftKey-0.2.0.zip)

Version 0.2.0 is signed with a Developer ID certificate, notarized by Apple,
and includes a stapled notarization ticket. WhisperSwiftKey is distributed
directly because the cross-application Accessibility APIs it needs are not
available to Mac App Store sandboxed apps.

## Features

- Double-tap Fn/Globe to start and stop dictation at the active text cursor
- Real-time transcription preview at the active text cursor while speaking
- Floating microphone feedback near the caret and a stable transcript panel
- System-audio transcription for calls, videos, and other audio playing on the Mac
- Push-to-talk and tap-to-toggle modes
- Multiple on-device Whisper models with automatic language detection
- Searchable local transcription history and custom vocabulary
- Completely on-device transcription after the selected model is downloaded

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)
- Microphone permission
- Accessibility permission (for text insertion)
- Screen Recording permission (only for optional system-audio transcription)
- Internet access for the initial Whisper model download

## Install and use

1. Download and unzip `WhisperSwiftKey-0.2.0.zip`.
2. Move `WhisperSwiftKey.app` to `/Applications` before opening it.
3. Open the app and complete its onboarding steps.
4. Grant Microphone and Accessibility access when prompted.
5. Choose and download a Whisper model.
6. Place the text cursor in any editable field, then double-tap Fn/Globe to
   start dictating. Double-tap again to stop.

WhisperSwiftKey is a menu bar app and does not appear in the Dock. If Fn/Globe
does not activate dictation, check **System Settings → Keyboard** for a macOS
shortcut that is already using that key.

To transcribe audio playing on the Mac, choose **Transcribe System Audio…**
from the menu-bar menu. macOS will request Screen Recording access the first
time this feature is used; WhisperSwiftKey captures the audio track and keeps
transcription on-device.

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
- **ScreenCaptureKit** for optional system-audio capture
- **UserDefaults-backed Codable storage** for local transcription history
- **CGEvent** tap for global hotkey detection
- **Accessibility API** for text insertion at cursor

## License

MIT
