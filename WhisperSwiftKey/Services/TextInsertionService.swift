import AppKit
import ApplicationServices

protocol TextInsertionServing: AnyObject {
    @discardableResult
    func beginProvisionalInsertionSession(targetApplicationPID: pid_t?) -> Bool
    func updateProvisionalText(_ text: String) -> Bool
    func commitProvisionalText(_ text: String) -> Bool
    func cancelProvisionalInsertionSession()
    func insertText(_ text: String)
}

extension TextInsertionServing {
    @discardableResult
    func beginProvisionalInsertionSession() -> Bool {
        beginProvisionalInsertionSession(targetApplicationPID: nil)
    }
}

/// Inserts transcribed text at the cursor position using Accessibility API or clipboard fallback
class TextInsertionService: TextInsertionServing {

    private struct ProvisionalInsertionSession {
        let targetElement: AXUIElement
        let originalText: String
        var currentText: String
        var range: NSRange
    }

    private var provisionalSession: ProvisionalInsertionSession?

    // Known terminal bundle IDs that need Cmd+V instead of AX API
    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
    ]

    /// Captures the exact field and selection that owned the caret before any
    /// non-activating dictation windows are shown. Streaming updates remain
    /// attached to this range even if Whisper revises its earlier hypothesis.
    @discardableResult
    func beginProvisionalInsertionSession(targetApplicationPID: pid_t?) -> Bool {
        cancelProvisionalInsertionSession()

        let frontmostApp: NSRunningApplication?
        if let targetApplicationPID {
            frontmostApp = NSRunningApplication(processIdentifier: targetApplicationPID)
        } else {
            frontmostApp = NSWorkspace.shared.frontmostApplication
        }

        guard let frontmostApp else { return false }
        let bundleID = frontmostApp.bundleIdentifier ?? ""
        guard !terminalBundleIDs.contains(bundleID) else { return false }

        let applicationElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        guard let focusedElement = getFocusedElement(applicationElement),
              let (currentValue, selectedRange) = textAndSelection(of: focusedElement) else {
            print("[TextInsertionService] Could not capture the focused text range for live dictation")
            return false
        }

        let nsCurrentValue = currentValue as NSString
        let safeLocation = max(0, min(selectedRange.location, nsCurrentValue.length))
        let safeLength = max(0, min(selectedRange.length, nsCurrentValue.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        let originalText = nsCurrentValue.substring(with: safeRange)

        provisionalSession = ProvisionalInsertionSession(
            targetElement: focusedElement,
            originalText: originalText,
            currentText: originalText,
            range: safeRange
        )
        return true
    }

    /// Atomically replaces the one range owned by this dictation session.
    /// No clipboard paste or inferred suffix is used for streaming hypotheses.
    @discardableResult
    func updateProvisionalText(_ text: String) -> Bool {
        replaceProvisionalText(with: text)
    }

    /// Applies the polished final hypothesis to the same owned range. Returns
    /// false when the target did not expose a safe editable AX text range.
    @discardableResult
    func commitProvisionalText(_ text: String) -> Bool {
        guard provisionalSession != nil else { return false }
        let didCommit = replaceProvisionalText(with: text)
        provisionalSession = nil
        return didCommit
    }

    /// Removes any text preview inserted by the current session and restores an
    /// original selection, if one existed.
    func cancelProvisionalInsertionSession() {
        guard let session = provisionalSession else { return }
        if session.currentText != session.originalText {
            _ = replaceProvisionalText(with: session.originalText)
        }
        provisionalSession = nil
    }

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

    private func replaceProvisionalText(with newText: String) -> Bool {
        guard var session = provisionalSession,
              let (currentValue, _) = textAndSelection(of: session.targetElement) else {
            return false
        }

        if session.currentText == newText {
            return true
        }

        let nsCurrentValue = currentValue as NSString
        guard session.range.location >= 0,
              session.range.length >= 0,
              NSMaxRange(session.range) <= nsCurrentValue.length,
              nsCurrentValue.substring(with: session.range) == session.currentText else {
            print("[TextInsertionService] Live dictation range changed externally; refusing to overwrite document text")
            return false
        }

        let delta = Self.minimalReplacement(from: session.currentText, to: newText)
        var changedDocumentRange = CFRange(
            location: session.range.location + delta.range.location,
            length: delta.range.length
        )

        // Most streaming hypotheses only append text or revise a short suffix.
        // Replacing that minimal span keeps the real editor caret at (or close to)
        // its current location instead of selecting the entire dictated sentence.
        let selectedTextResult: AXError
        if let rangeValue = AXValueCreate(.cfRange, &changedDocumentRange),
           AXUIElementSetAttributeValue(
            session.targetElement,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
           ) == .success {
            selectedTextResult = AXUIElementSetAttributeValue(
                session.targetElement,
                kAXSelectedTextAttribute as CFString,
                delta.replacement as CFTypeRef
            )
        } else {
            selectedTextResult = .failure
        }

        if selectedTextResult != .success {
            // Compatibility fallback for controls that expose a writable value but
            // not selected-text editing. The owned range was validated above.
            let updatedValue = nsCurrentValue.replacingCharacters(in: session.range, with: newText)
            guard AXUIElementSetAttributeValue(
                session.targetElement,
                kAXValueAttribute as CFString,
                updatedValue as CFTypeRef
            ) == .success else {
                return false
            }
        }

        let insertedLength = (newText as NSString).length
        var newCaret = CFRange(location: session.range.location + insertedLength, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &newCaret) {
            _ = AXUIElementSetAttributeValue(
                session.targetElement,
                kAXSelectedTextRangeAttribute as CFString,
                caretValue
            )
        }

        session.currentText = newText
        session.range.length = insertedLength
        provisionalSession = session
        return true
    }

    /// Finds the smallest whole-character span that changes between two Whisper
    /// hypotheses. The returned range uses UTF-16 offsets, matching AX CFRange.
    static func minimalReplacement(from oldText: String, to newText: String) -> (range: NSRange, replacement: String) {
        let oldCharacters = Array(oldText)
        let newCharacters = Array(newText)
        let sharedLimit = min(oldCharacters.count, newCharacters.count)

        var sharedPrefixCount = 0
        while sharedPrefixCount < sharedLimit,
              oldCharacters[sharedPrefixCount] == newCharacters[sharedPrefixCount] {
            sharedPrefixCount += 1
        }

        var sharedSuffixCount = 0
        while sharedSuffixCount < sharedLimit - sharedPrefixCount,
              oldCharacters[oldCharacters.count - 1 - sharedSuffixCount]
                == newCharacters[newCharacters.count - 1 - sharedSuffixCount] {
            sharedSuffixCount += 1
        }

        let oldStart = oldText.index(oldText.startIndex, offsetBy: sharedPrefixCount)
        let oldEnd = oldText.index(oldText.endIndex, offsetBy: -sharedSuffixCount)
        let newStart = newText.index(newText.startIndex, offsetBy: sharedPrefixCount)
        let newEnd = newText.index(newText.endIndex, offsetBy: -sharedSuffixCount)

        return (
            NSRange(oldStart..<oldEnd, in: oldText),
            String(newText[newStart..<newEnd])
        )
    }

    private func textAndSelection(of element: AXUIElement) -> (String, CFRange)? {
        var currentValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValueRef
        ) == .success,
        let currentValue = currentValueRef as? String else {
            return nil
        }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let axRangeValue = selectedRangeRef,
        CFGetTypeID(axRangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRangeValue as! AXValue, .cfRange, &selectedRange) else {
            return nil
        }
        return (currentValue, selectedRange)
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

    private func getFocusedElement(_ systemElement: AXUIElement) -> AXUIElement? {
        // An application AX element exposes its focused UI element directly.
        var directFocusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &directFocusedElement
        ) == .success,
        let directFocusedElement {
            return (directFocusedElement as! AXUIElement)
        }

        // System-wide elements require resolving the focused application first.
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        return (focusedElement as! AXUIElement)
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
