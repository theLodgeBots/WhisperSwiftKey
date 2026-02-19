# WhisperSwiftKey — Status & Testing Checklist

**Last updated:** 2026-02-19
**Branch:** main
**Build status:** ✅ Compiles (Debug, macOS 14+, Apple Silicon)
**Tested:** ❌ Not yet — needs manual testing

---

## What's Built

### Core Pipeline (P0)
- [x] WhisperKit integration (SPM dependency v0.9+)
- [x] 16kHz mono audio capture via AVAudioConverter
- [x] Transcription with WhisperKit `transcribe(audioArrays:)`
- [x] Auto-paste at cursor (Accessibility API + clipboard fallback)
- [x] Terminal app detection (uses Cmd+V for Terminal, iTerm2, Alacritty, Kitty, WezTerm, Ghostty)
- [x] Menu bar app (LSUIElement, mic icon with pulse animation)
- [x] Model management UI (select model, triggers download, shows active)
- [x] 4-step onboarding wizard (welcome → permissions → model select → test drive)

### Features (P1)
- [x] Double-tap Fn hotkey to toggle recording
- [x] Push-to-talk mode (hold Fn to record, release to stop)
- [x] Recording mode selector in Settings (tap-to-toggle vs push-to-talk)
- [x] Custom dictionary / prompt hints (word list → WhisperKit prompt tokens)
- [x] Draggable floating recording overlay (HUD panel, auto-dismiss)
- [ ] Customizable hotkey combos (currently Fn-only)

### Features (P2)
- [x] 28-language dropdown + auto-detect
- [x] Transcription history (SwiftData, searchable, copy-to-clipboard, context menu)
- [x] History includes: timestamp, word count, duration, language, frontmost app

### Features (P3 — UI only, not wired)
- [x] Agent name setting in UI
- [ ] Actual LLM routing for agent commands (no local model integration yet)

---

## Testing Checklist

### First Launch
- [ ] App appears in menu bar (mic icon)
- [ ] Onboarding window shows on first launch
- [ ] Microphone permission prompt appears and can be granted
- [ ] Accessibility permission link opens System Settings correctly
- [ ] Model download starts and completes (try Large V3 Turbo first)
- [ ] Test dictation works in onboarding step 4

### Core Recording
- [ ] Double-tap Fn starts recording (mic icon pulses)
- [ ] Double-tap Fn again stops recording
- [ ] Transcription result appears in menu bar dropdown
- [ ] Text is auto-inserted at cursor position in a text editor
- [ ] Text is auto-inserted in Terminal via Cmd+V (not AX API)
- [ ] Works in Safari/Chrome text inputs

### Recording Overlay
- [ ] Floating overlay appears when recording starts
- [ ] Shows "Recording..." with red dot
- [ ] Changes to "Transcribing..." during processing
- [ ] Shows result briefly, then auto-dismisses
- [ ] Overlay is draggable
- [ ] Can be disabled in Settings

### Push-to-Talk
- [ ] Switch to push-to-talk in Settings → General
- [ ] Hold Fn → recording starts
- [ ] Release Fn → recording stops and transcribes
- [ ] Works for short phrases (1-2 seconds)

### Models
- [ ] Settings → Models shows all 5 models
- [ ] Selecting a new model triggers download
- [ ] Active model shows checkmark
- [ ] Recommended badge shows on Large V3 Turbo

### Custom Dictionary
- [ ] Can add words in Settings → Dictionary
- [ ] Can remove words
- [ ] Words improve recognition of unusual names/terms
- [ ] Clear All works

### History
- [ ] Transcriptions appear in Settings → History
- [ ] Search filters results
- [ ] Right-click → Copy works
- [ ] Clear All removes all entries
- [ ] Shows word count, duration, relative time

### Language
- [ ] Auto-detect works (default)
- [ ] Pinning a language (e.g., Spanish) transcribes in that language
- [ ] All 28 languages appear in dropdown

### Edge Cases
- [ ] No crash if Fn double-tapped before model loads
- [ ] Error shown if no mic permission
- [ ] Works after sleep/wake
- [ ] Multiple transcriptions in a row work without issues
- [ ] Long recording (30+ seconds) works

---

## Known Gaps / Future Work

1. **Custom hotkey combos** (P1) — currently only Fn. Need key combo recorder UI + CGEvent handling for arbitrary modifier combos
2. **Agent LLM routing** (P3) — UI toggle exists but no local model (MLX/llama.cpp) integration
3. **Model download progress** — WhisperKit handles download internally; no granular progress bar exposed yet
4. **Model deletion** — no UI to delete cached models / show disk usage
5. **Onboarding auto-show** — Window scene declared but may need `openWindow` environment action to auto-present on first launch
6. **Sound feedback** — no audio cue on successful transcription (could add system sound)
7. **Append mode** — no option to append vs replace selection
8. **Trailing newline option** — useful for terminal commands

---

## Architecture

```
WhisperSwiftKeyApp.swift          — @main, MenuBarExtra + Settings + Onboarding scenes
Models/
  AppState.swift                  — Central state, services, SwiftData context
  Transcription.swift             — SwiftData model for history
Services/
  AudioService.swift              — Mic capture → 16kHz Float samples
  WhisperService.swift            — WhisperKit wrapper (load/transcribe)
  HotkeyService.swift             — CGEvent tap for Fn detection (double-tap + push-to-talk)
  TextInsertionService.swift      — AX API text insertion + clipboard fallback
Views/
  MenuBarView.swift               — Menu bar dropdown UI
  SettingsView.swift              — 4-tab settings (General, Models, Dictionary, History)
  OnboardingView.swift            — 4-step first-run wizard
  RecordingOverlayView.swift      — Floating HUD panel
```

## Dependencies
- **WhisperKit** 0.9+ (resolved to 0.15.0) — on-device Whisper inference
- **swift-transformers** 1.1.6 — tokenizer for prompt encoding
- macOS 14.0+, Swift 5.9, Xcode 15+
