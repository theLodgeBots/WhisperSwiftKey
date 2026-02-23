import AppKit
import ApplicationServices

/// Inserts transcribed text at the cursor position using Accessibility API or clipboard fallback
class TextInsertionService {

    // Known terminal bundle IDs that need Cmd+V instead of AX API
    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
    ]

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier ?? ""

        if terminalBundleIDs.contains(bundleID) {
            insertViaClipboard(text)
        } else if !insertViaAccessibilityAtCursor(text) {
            insertViaClipboard(text)
        }
    }

    /// Insert incremental dictation text at the cursor. Uses paste to avoid replacing full field contents.
    func insertIncrementalText(_ text: String) {
        guard !text.isEmpty else { return }
        insertViaClipboard(text)
    }

    /// Replace a known placeholder (e.g. "...") or short streaming text with the final transcription.
    /// Uses AX replace first; if that fails, safely falls back to keyboard backspaces + paste
    /// since we know exactly what text we inserted and how long it is.
    func replacePlaceholderText(_ previousText: String, with newText: String) {
        guard !previousText.isEmpty else {
            insertIncrementalText(newText)
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier ?? ""

        if terminalBundleIDs.contains(bundleID) {
            replaceViaKeyboard(previousText: previousText, newText: newText)
            return
        }

        if !replaceTrailingTextViaAccessibility(previousText: previousText, newText: newText) {
            // AX failed — safe to use keyboard backspaces since we know the exact
            // placeholder text we inserted (e.g. "...") is right before the caret.
            print("[TextInsertionService] AX replace failed for placeholder, using keyboard fallback")
            replaceViaKeyboard(previousText: previousText, newText: newText)
        }
    }

    /// Replace the most recently inserted dictation text with updated text (Siri-like provisional update).
    func replaceRecentlyInsertedText(_ previousText: String, with newText: String) {
        guard !previousText.isEmpty else {
            insertIncrementalText(newText)
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier ?? ""

        if terminalBundleIDs.contains(bundleID) {
            replaceViaKeyboard(previousText: previousText, newText: newText)
            return
        }

        if !replaceTrailingTextViaAccessibility(previousText: previousText, newText: newText) {
            // AX replace failed. Only use keyboard backspaces in terminals (above).
            // For other apps, skip rather than sending blind backspaces that could
            // delete existing document content.
            print("[TextInsertionService] AX replace failed, skipping keyboard fallback to protect document content")
        }
    }

    /// Try inserting via Accessibility API at the caret/selection (Siri-like behavior).
    /// Falls back to clipboard paste if the app does not expose the required AX text attributes.
    private func insertViaAccessibilityAtCursor(_ text: String) -> Bool {
        guard let systemElement = AXUIElementCreateSystemWide() as AXUIElement?,
              let focusedElement = getFocusedElement(systemElement) else {
            return false
        }

        var currentValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &currentValueRef) == .success,
              let currentValue = currentValueRef as? String else {
            return false
        }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let axRangeValue = selectedRangeRef,
              CFGetTypeID(axRangeValue) == AXValueGetTypeID() else {
            return false
        }

        let rangeValue = axRangeValue as! AXValue
        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return false
        }

        let nsCurrentValue = currentValue as NSString
        let safeLocation = max(0, min(selectedRange.location, nsCurrentValue.length))
        let safeLength = max(0, min(selectedRange.length, nsCurrentValue.length - safeLocation))
        let replacementRange = NSRange(location: safeLocation, length: safeLength)

        let updatedValue = nsCurrentValue.replacingCharacters(in: replacementRange, with: text)
        let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, updatedValue as CFTypeRef)
        guard setResult == .success else {
            return false
        }

        var newCaret = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &newCaret) {
            _ = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }

        return true
    }

    /// Fallback: copy to clipboard and simulate Cmd+V
    private func insertViaClipboard(_ text: String) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulateKeyPress(keyCode: 9, flags: .maskCommand) // 'V' key

        // Restore clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func replaceViaKeyboard(previousText: String, newText: String) {
        let deleteCount = max(0, (previousText as NSString).length)
        for _ in 0..<deleteCount {
            simulateKeyPress(keyCode: 51, flags: []) // Delete (backspace)
        }
        if !newText.isEmpty {
            insertViaClipboard(newText)
        }
    }

    /// Attempts to replace the text immediately before the caret, if it matches the previous provisional dictation text.
    /// Uses AX only to validate/select the range, then pastes over the selection to preserve rich-text formatting.
    private func replaceTrailingTextViaAccessibility(previousText: String, newText: String) -> Bool {
        guard let systemElement = AXUIElementCreateSystemWide() as AXUIElement?,
              let focusedElement = getFocusedElement(systemElement) else {
            return false
        }

        var currentValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &currentValueRef) == .success,
              let currentValue = currentValueRef as? String else {
            return false
        }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let axRangeValue = selectedRangeRef,
              CFGetTypeID(axRangeValue) == AXValueGetTypeID() else {
            return false
        }

        let rangeValue = axRangeValue as! AXValue
        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return false
        }

        // Only do provisional replacement when the caret is collapsed.
        guard selectedRange.length == 0 else { return false }

        let nsCurrentValue = currentValue as NSString
        let oldLen = (previousText as NSString).length
        let safeCaretLocation = max(0, min(selectedRange.location, nsCurrentValue.length))
        guard safeCaretLocation >= oldLen else { return false }

        let replacementRange = NSRange(location: safeCaretLocation - oldLen, length: oldLen)
        let currentTrailing = nsCurrentValue.substring(with: replacementRange)
        guard currentTrailing == previousText else { return false }

        var selectionToReplace = CFRange(location: replacementRange.location, length: replacementRange.length)
        guard let selectionValue = AXValueCreate(.cfRange, &selectionToReplace) else { return false }
        let selectResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            selectionValue
        )
        guard selectResult == .success else { return false }

        if newText.isEmpty {
            simulateKeyPress(keyCode: 51, flags: []) // Delete selection
        } else {
            insertViaClipboard(newText)
        }
        return true
    }

    private func getFocusedElement(_ systemElement: AXUIElement) -> AXUIElement? {
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        return focusedElement as! AXUIElement?
    }

    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
