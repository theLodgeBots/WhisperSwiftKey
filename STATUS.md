# WhisperSwiftKey — Status & Testing Checklist

**Last updated:** 2026-08-18
**Branch:** main
**Release candidate:** 0.2.0 (build 4)
**Automated tests:** 21 passing

## Current functionality

- On-device microphone dictation through WhisperKit 0.18.0.
- Double-tap Fn/Globe and push-to-talk recording modes.
- Live transcript preview written into a verified Accessibility range.
- Floating microphone feedback near the caret plus a stable transcript panel.
- Safe final insertion with clipboard fallback for browsers and terminals.
- On-device system-audio capture through ScreenCaptureKit.
- Searchable local transcription history and custom vocabulary.
- Model download, selection, sleep/wake, disk usage, and deletion controls.
- Duplicate-instance protection and Fn/Globe diagnostics.

## Automated coverage

- Streaming hypotheses replace instead of duplicate earlier words.
- Rejected Accessibility writes stop further provisional document changes.
- Final insertion falls back safely when no provisional range exists.
- Duplicate async finalization is ignored.
- Browser and terminal bundle identifiers select clipboard insertion.
- Speech gating rejects silence and accepts short voiced audio.
- Low-confidence/no-speech Whisper hallucinations are filtered.
- System-audio chunks split at a recent quiet point.
- A native text view receives the exact streaming hypothesis and exposes caret bounds.

Run the suite with:

```sh
xcodebuild \
  -project WhisperSwiftKey.xcodeproj \
  -scheme WhisperSwiftKey \
  -destination 'platform=macOS' \
  test
```

## Release smoke checklist

- [x] Debug and Release configurations compile.
- [x] All automated tests pass.
- [x] Developer ID signature verifies.
- [x] Apple notarization ticket is stapled.
- [x] Gatekeeper accepts the exported app.
- [ ] Dictation inserts once in TextEdit.
- [ ] Dictation inserts once in a browser text field.
- [ ] Floating microphone follows the active caret without moving the transcript panel.
- [ ] System-audio start, live update, stop, copy, and history flow works.
- [ ] Git tag, GitHub release, checksum, and README download link resolve.

Cross-application smoke tests must use the app from `/Applications` with
Accessibility permission granted to that exact signed build. Screen Recording
permission is required only for the optional system-audio feature.

## Known limitations

- Fn/Globe is the only global hotkey; arbitrary shortcuts are not yet configurable.
- Some protected streaming content cannot be captured by ScreenCaptureKit.
- Model files are downloaded separately on first use and are not bundled in releases.
