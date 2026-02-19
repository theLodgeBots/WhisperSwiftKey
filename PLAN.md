# Best Ideas from OpenWhispr → WhisperSwiftKey

> Analysis of [OpenWhispr](https://github.com/OpenWhispr/openwhispr) (1.3k★, Electron-based, cross-platform) and how to adopt their best features as native macOS implementations in WhisperSwiftKey.

---

## 1. Custom Dictionary / Prompt Hints

**What OpenWhispr does:** Users add words, names, and technical terms to a custom dictionary. These are passed to Whisper's `prompt` parameter as context hints, making the model more likely to recognize uncommon words correctly.

**Why it's great:** Whisper frequently butchers proper nouns, brand names, and jargon. This is a low-effort, high-impact feature.

**How to adopt in WhisperSwiftKey:**

- Store a user-editable word list in `UserDefaults` or a JSON file in Application Support
- Before each transcription, join the dictionary words into a prompt string
- Pass to WhisperKit via `DecodingOptions(prompt: dictionaryString)`
- SwiftUI settings panel with add/remove/import-from-file
- Bonus: auto-suggest words from macOS Contacts (names) and recent clipboard contents

```swift
// Example integration
let options = DecodingOptions(
    prompt: customDictionary.joined(separator: ", "),
    language: selectedLanguage
)
let result = try await whisperKit.transcribe(audioBuffer: buffer, decoding: options)
```

---

## 2. Agent Naming + AI Command Detection

**What OpenWhispr does:** Users name an AI agent (e.g., "Jarvis"). When dictating, if the user says "Hey Jarvis, make this more professional," the app detects it as a command vs. regular dictation and routes it to an LLM for processing. Agent name is stripped from final output.

**Why it's great:** Turns a simple dictation tool into a voice-activated AI assistant. The agent name acts as a natural wake word for commands vs. plain text.

**How to adopt in WhisperSwiftKey:**

- Add optional agent name in settings (default: off, pure dictation mode)
- After transcription, check if text starts with "Hey {agentName}" pattern
- If detected: strip the prefix and route to a local LLM (via llama.cpp or MLX) or optional cloud API
- Commands: "make professional", "fix grammar", "summarize", "translate to Spanish", "format as bullet points"
- If no agent name detected: insert raw transcription as usual
- Keep this entirely optional — power user feature, not required for core flow

---

## 3. Transcription History with Local Database

**What OpenWhispr does:** Stores all transcriptions in a local SQLite database with timestamps, original text, processed text, processing method, and error tracking.

**Why it's great:** Users often want to recover something they dictated earlier. History also enables analytics (usage patterns, accuracy tracking).

**How to adopt in WhisperSwiftKey:**

- Use SwiftData (or raw SQLite via GRDB.swift) for local storage
- Schema:
  - `id`, `timestamp`, `originalText`, `processedText`, `durationSeconds`, `modelUsed`, `wordCount`
- Searchable history view in Settings window
- Copy-to-clipboard from history entries
- Auto-prune after configurable retention period (default: 30 days)
- Export to CSV/JSON for power users
- This data also feeds the adaptive sleep timer (usage frequency tracking)

---

## 4. Push-to-Talk Mode (Hold to Record)

**What OpenWhispr does:** On Windows, they built a native low-level keyboard hook for true push-to-talk — hold the hotkey to record, release to stop and transcribe.

**Why it's great:** More natural than tap-to-start / tap-to-stop for short commands. Users know exactly when recording starts and stops.

**How to adopt in WhisperSwiftKey:**

- Support both modes, user-selectable:
  - **Tap-to-toggle** (default): double-tap Fn to start, tap again to stop
  - **Push-to-talk**: hold Fn to record, release to stop
- Detect via CGEvent tap: `flagsChanged` events for key-down and key-up
- Push-to-talk is especially good for short commands ("open Safari", "new paragraph")
- Visual indicator changes: pulsing mic (tap mode) vs. solid mic (push-to-talk, clearly shows "recording while held")

---

## 5. Compound / Customizable Hotkeys

**What OpenWhispr does:** Supports multi-key combinations like `Cmd+Shift+K` in addition to single-key activation. Fully configurable through the UI.

**Why it's great:** Double-Fn is convenient but may conflict with macOS dictation or other tools. Users need flexibility.

**How to adopt in WhisperSwiftKey:**

- Settings panel with a "record hotkey" button — user presses desired combo and it's captured
- Support: single keys, modifier combos (Cmd+Shift+D), double-tap patterns
- Store as serialized `KeyCombo` struct in UserDefaults
- Detect conflicts with known macOS system shortcuts and warn
- Default: double-tap Fn, with easy one-click alternatives (e.g., `Ctrl+Space`)

---

## 6. Draggable Recording Overlay

**What OpenWhispr does:** A small floating panel appears during recording that shows recording state. Users can drag it anywhere on screen.

**Why it's great:** Non-intrusive visual feedback without taking over the screen. Position persistence means it stays where the user wants it.

**How to adopt in WhisperSwiftKey:**

- Small NSPanel (floating, non-activating) that appears near cursor or menu bar when recording starts
- Shows: waveform visualization, elapsed time, model name
- Draggable via standard NSWindow dragging
- Persists position across sessions
- States: 🔴 Recording → ⏳ Processing → ✅ Done (auto-dismiss after 1s)
- Option to disable entirely (menu bar icon animation is enough for some users)

---

## 7. Model Management UI with Disk Usage

**What OpenWhispr does:** Full model download manager showing available models, download progress, disk usage per model, and one-click cleanup. Includes uninstall hooks that clean up cached models.

**Why it's great:** Models are big (75MB–1.5GB). Users need visibility and control over what's eating their disk.

**How to adopt in WhisperSwiftKey:**

- Settings tab: "Models" showing:
  - Available models with size, quality rating, speed estimate
  - Download progress bar per model
  - Disk usage breakdown (total and per-model)
  - Delete button per model (with confirmation)
  - "Recommended for your device" badge (based on chip: M1 → base, M3 Pro → large-v3)
- WhisperKit already supports model download via HuggingFace — wrap with UI
- On app uninstall: provide a "Clean Up" menu item or include cleanup in DMG uninstaller

---

## 8. Automatic Paste at Cursor

**What OpenWhispr does:** After transcription, text is automatically pasted at the cursor position. On macOS they use Accessibility APIs, with clipboard-paste as fallback. They also detect terminal emulators and use Ctrl+Shift+V instead of Ctrl+V.

**Why it's great:** This is the core UX differentiator vs. just copying to clipboard. Zero-friction: speak → text appears.

**How to adopt in WhisperSwiftKey (already planned, but add these details):**

- **Terminal detection:** Check `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` for known terminals (Terminal.app, iTerm2, Alacritty, Kitty, WezTerm, Ghostty) and use Cmd+V paste instead of AX API
- **Web input detection:** For Safari/Chrome text inputs, AX API may not work — fall back to clipboard paste
- **Append mode:** Optional setting to append to existing text instead of replacing selection
- **Newline handling:** Option to add a trailing newline (useful for terminal commands)
- **Sound feedback:** Subtle system sound on successful insertion (like macOS dictation)

---

## 9. Onboarding Flow

**What OpenWhispr does:** 3-step first-run wizard: permissions → model download → test dictation.

**Why it's great:** macOS apps that need Accessibility + Microphone permissions are confusing for new users. Guided setup dramatically reduces drop-off.

**How to adopt in WhisperSwiftKey:**

- Step 1: **Welcome** — explain what the app does, privacy promise
- Step 2: **Permissions** — guide through Microphone + Accessibility grants with direct deep links to System Settings
- Step 3: **Choose Model** — recommend based on device, download with progress
- Step 4: **Test Drive** — "Press Fn twice and say something!" with live feedback
- Step 5: **Done** — show the menu bar icon, explain how to access settings
- Can be re-triggered from Settings → "Run Setup Again"

---

## 10. Multi-Language Support with Auto-Detection

**What OpenWhispr does:** Supports 58 languages with optional language pinning or auto-detection.

**Why it's great:** WhisperKit supports this natively — just need to expose it properly.

**How to adopt in WhisperSwiftKey:**

- Settings: language dropdown with "Auto-detect" as default
- Pin a primary language for faster/more accurate results
- Show detected language in the recording overlay after transcription
- Respect macOS system language as the default suggestion
- Per-app language profiles (future): e.g., always use Spanish in WhatsApp

---

## 11. Transcription History Database Schema

**Inspired by OpenWhispr's SQLite schema, adapted for SwiftData:**

```swift
@Model
class Transcription {
    var id: UUID
    var timestamp: Date
    var originalText: String
    var processedText: String?  // After AI processing (if agent mode)
    var isProcessed: Bool
    var processingMethod: String  // "none", "local_llm", "openai"
    var agentName: String?
    var durationSeconds: Double
    var modelUsed: String  // "base", "large-v3", etc.
    var wordCount: Int
    var language: String?
    var errorMessage: String?
    var appContext: String?  // Bundle ID of frontmost app during dictation
}
```

---

## 12. Globe/Fn Key Native Swift Helper

**What OpenWhispr does:** On macOS, they bundle a compiled Swift helper binary for Globe key detection, requiring Xcode Command Line Tools.

**Why it's great for us:** Since WhisperSwiftKey is already native Swift, we don't need a separate helper — we can detect Fn/Globe directly in-process, which is cleaner and has zero setup overhead.

**Advantage over OpenWhispr:** No Xcode CLI tools required for users. No separate binary to manage. Just works.

---

## 13. Ideas NOT to Adopt

Some OpenWhispr features that don't make sense for WhisperSwiftKey:

| OpenWhispr Feature | Why Skip It |
|---|---|
| Electron framework | We're native Swift — 10x lighter, faster startup |
| Cloud transcription / BYOK API keys | Our differentiator is 100% on-device. Keep it pure. |
| Account system / subscriptions | Open source, no accounts needed |
| React/TypeScript UI | SwiftUI is native and more appropriate |
| Cross-platform (Windows/Linux) | macOS-only focus = better quality, simpler codebase |
| Multiple cloud AI providers | If we add AI post-processing, use local models only (MLX/llama.cpp) |

---

## Priority Ranking for WhisperSwiftKey

| Priority | Feature | Effort | Impact |
|---|---|---|---|
| **P0** | Automatic paste at cursor (with terminal detection) | Medium | Critical |
| **P0** | Model management UI with disk usage | Medium | High |
| **P0** | Onboarding flow | Medium | High |
| **P1** | Custom dictionary / prompt hints | Low | High |
| **P1** | Push-to-talk mode | Low | High |
| **P1** | Compound / customizable hotkeys | Medium | Medium |
| **P1** | Draggable recording overlay | Low | Medium |
| **P2** | Transcription history | Medium | Medium |
| **P2** | Multi-language with auto-detect | Low | Medium |
| **P3** | Agent naming + AI commands (local LLM) | High | Medium |

---

*Document generated February 2026. Based on analysis of OpenWhispr v1.4.11 (MIT License).*
