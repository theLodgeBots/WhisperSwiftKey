import AppKit
import ApplicationServices

enum ProvisionalTextCommitResult: Equatable {
    /// The final text replaced the provisional text in the target editor.
    case committed
    /// No provisional dictation text was inserted, so a normal paste is safe.
    case needsFallbackInsertion
    /// Provisional text may remain, but its exact state could not be resolved
    /// safely. A blind paste would risk duplication, so the document is left alone.
    case provisionalTextPreserved
}

protocol TextInsertionServing: AnyObject {
    @discardableResult
    func beginProvisionalInsertionSession(targetApplicationPID: pid_t?) -> Bool
    func updateProvisionalText(_ text: String) -> Bool
    func commitProvisionalText(_ text: String) -> ProvisionalTextCommitResult
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
        struct UnverifiedMutation {
            let previousValue: String
            let expectedValue: String
            let attemptedText: String
        }

        let targetElement: AXUIElement
        let targetApplicationPID: pid_t
        let originalText: String
        var currentText: String
        var range: NSRange
        var unverifiedMutation: UnverifiedMutation?
    }

    private var provisionalSession: ProvisionalInsertionSession?

    // Known terminal bundle IDs that need Cmd+V instead of AX API
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
    ]

    // Web browsers expose contenteditable areas (Gmail, Google Docs, ...) through
    // an AX tree whose reported value and selected range do not reliably match the
    // page's real editor state. Provisional AX writes there can land at the wrong
    // location (often offset 0) and cannot be verified by read-back, which then
    // triggers a duplicate fallback paste at commit. These apps always use a
    // single Cmd+V paste at the real caret instead.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "com.duckduckgo.macos.browser",
    ]

    /// Apps where streaming provisional AX edits are unsafe, so the final
    /// transcript is delivered with one clipboard paste at the caret.
    static func usesClipboardOnlyInsertion(bundleID: String) -> Bool {
        if terminalBundleIDs.contains(bundleID) || browserBundleIDs.contains(bundleID) {
            return true
        }
        // Cover channel variants such as com.google.Chrome.beta/.canary.
        return browserBundleIDs.contains { bundleID.hasPrefix($0 + ".") }
    }

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
        guard !Self.usesClipboardOnlyInsertion(bundleID: bundleID) else { return false }

        let applicationElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        guard let focusedElement = getFocusedElement(applicationElement),
              let (currentValue, selectedRange) = textAndSelection(of: focusedElement) else {
            print("[TextInsertionService] Could not capture the focused text range for live dictation")
            return false
        }

        // Electron and other embedded-Chromium apps have the same unreliable web
        // AX semantics as browsers but arbitrary bundle IDs. Detect web content
        // structurally and fall back to a single paste at commit.
        if isInsideWebArea(focusedElement) {
            print("[TextInsertionService] Focused element is web content; using clipboard-only insertion")
            return false
        }

        let nsCurrentValue = currentValue as NSString
        let safeLocation = max(0, min(selectedRange.location, nsCurrentValue.length))
        let safeLength = max(0, min(selectedRange.length, nsCurrentValue.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        let originalText = nsCurrentValue.substring(with: safeRange)

        provisionalSession = ProvisionalInsertionSession(
            targetElement: focusedElement,
            targetApplicationPID: frontmostApp.processIdentifier,
            originalText: originalText,
            currentText: originalText,
            range: safeRange,
            unverifiedMutation: nil
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
    /// a result that tells the caller whether a normal paste is still safe.
    @discardableResult
    func commitProvisionalText(_ text: String) -> ProvisionalTextCommitResult {
        guard let storedSession = provisionalSession else {
            return .needsFallbackInsertion
        }

        if replaceProvisionalText(with: text) {
            provisionalSession = nil
            return .committed
        }

        let session = provisionalSession ?? storedSession
        if session.unverifiedMutation != nil {
            provisionalSession = nil
            return .provisionalTextPreserved
        }

        // If a verified partial is still present, make one final compatibility
        // attempt through the editor's normal paste handling. This is safer for
        // rich text, Messages, and browser-backed controls than setting AXValue.
        if session.currentText != session.originalText {
            let recovered = replaceProvisionalTextViaClipboard(
                with: text,
                session: session
            )
            provisionalSession = nil
            return recovered ? .committed : .provisionalTextPreserved
        }

        provisionalSession = nil
        return .needsFallbackInsertion
    }

    /// Removes any text preview inserted by the current session and restores an
    /// original selection, if one existed.
    func cancelProvisionalInsertionSession() {
        guard let storedSession = provisionalSession else { return }
        if let session = reconcileUnverifiedMutation(in: storedSession),
           session.currentText != session.originalText {
            _ = replaceProvisionalText(with: session.originalText)
        }
        provisionalSession = nil
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        // A normal paste is the most compatible final-delivery path. In
        // particular, browser and Messages controls can report a successful
        // AXValue write without updating their underlying editor.
        _ = insertViaClipboard(text)
    }

    private func replaceProvisionalText(with newText: String) -> Bool {
        guard let storedSession = provisionalSession,
              let session = reconcileUnverifiedMutation(in: storedSession),
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
        let expectedValue = nsCurrentValue.replacingCharacters(
            in: session.range,
            with: newText
        )
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

        if selectedTextResult == .success {
            switch mutationVerification(
                of: session.targetElement,
                previousValue: currentValue,
                expectedValue: expectedValue
            ) {
            case .applied:
                return finishVerifiedReplacement(
                    newText,
                    session: session
                )
            case .changedUnexpectedly:
                print("[TextInsertionService] AX selected-text write changed the editor unexpectedly")
                rememberUnverifiedMutation(
                    previousValue: currentValue,
                    expectedValue: expectedValue,
                    attemptedText: newText,
                    session: session
                )
                return false
            case .unchanged:
                break
            }
        }

        if selectedTextResult != .success || textValue(of: session.targetElement) == currentValue {
            // Compatibility fallback for controls that expose a writable value but
            // not selected-text editing. The owned range was validated above.
            guard AXUIElementSetAttributeValue(
                session.targetElement,
                kAXValueAttribute as CFString,
                expectedValue as CFTypeRef
            ) == .success else {
                restoreSelection(afterFailedReplacementFor: session)
                return false
            }
        }

        switch mutationVerification(
            of: session.targetElement,
            previousValue: currentValue,
            expectedValue: expectedValue
        ) {
        case .applied:
            return finishVerifiedReplacement(newText, session: session)
        case .unchanged:
            print("[TextInsertionService] AX write reported success but the editor text did not change")
            restoreSelection(afterFailedReplacementFor: session)
        case .changedUnexpectedly:
            print("[TextInsertionService] AX write changed the editor unexpectedly")
            rememberUnverifiedMutation(
                previousValue: currentValue,
                expectedValue: expectedValue,
                attemptedText: newText,
                session: session
            )
        }
        return false
    }

    private func finishVerifiedReplacement(
        _ newText: String,
        session originalSession: ProvisionalInsertionSession
    ) -> Bool {
        var session = originalSession
        let insertedLength = (newText as NSString).length
        setSelectedRange(
            CFRange(location: session.range.location + insertedLength, length: 0),
            on: session.targetElement
        )
        session.currentText = newText
        session.range.length = insertedLength
        session.unverifiedMutation = nil
        provisionalSession = session
        return true
    }

    private func rememberUnverifiedMutation(
        previousValue: String,
        expectedValue: String,
        attemptedText: String,
        session originalSession: ProvisionalInsertionSession
    ) {
        var session = originalSession
        session.unverifiedMutation = .init(
            previousValue: previousValue,
            expectedValue: expectedValue,
            attemptedText: attemptedText
        )
        provisionalSession = session
    }

    private func reconcileUnverifiedMutation(
        in originalSession: ProvisionalInsertionSession
    ) -> ProvisionalInsertionSession? {
        guard let mutation = originalSession.unverifiedMutation else {
            return originalSession
        }
        guard let observedValue = textValue(of: originalSession.targetElement) else {
            return nil
        }

        var session = originalSession
        if observedValue == mutation.expectedValue {
            session.currentText = mutation.attemptedText
            session.range.length = (mutation.attemptedText as NSString).length
            session.unverifiedMutation = nil
            provisionalSession = session
            return session
        }
        if observedValue == mutation.previousValue {
            session.unverifiedMutation = nil
            provisionalSession = session
            return session
        }
        return nil
    }

    private enum MutationVerification {
        case applied
        case unchanged
        case changedUnexpectedly
    }

    private func mutationVerification(
        of element: AXUIElement,
        previousValue: String,
        expectedValue: String
    ) -> MutationVerification {
        guard let observedValue = textValue(of: element) else {
            return .changedUnexpectedly
        }
        if observedValue == expectedValue {
            return .applied
        }
        return observedValue == previousValue ? .unchanged : .changedUnexpectedly
    }

    private func restoreSelection(afterFailedReplacementFor session: ProvisionalInsertionSession) {
        let selection: CFRange
        if session.currentText == session.originalText {
            selection = CFRange(
                location: session.range.location,
                length: session.range.length
            )
        } else {
            selection = CFRange(
                location: NSMaxRange(session.range),
                length: 0
            )
        }
        setSelectedRange(selection, on: session.targetElement)
    }

    private func replaceProvisionalTextViaClipboard(
        with newText: String,
        session: ProvisionalInsertionSession
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(session.targetApplicationPID)
        guard let focusedElement = getFocusedElement(applicationElement),
              CFEqual(focusedElement, session.targetElement),
              let (currentValue, _) = textAndSelection(of: focusedElement) else {
            return false
        }

        let nsCurrentValue = currentValue as NSString
        guard session.range.location >= 0,
              session.range.length >= 0,
              NSMaxRange(session.range) <= nsCurrentValue.length,
              nsCurrentValue.substring(with: session.range) == session.currentText else {
            return false
        }

        let replacementRange = CFRange(
            location: session.range.location,
            length: session.range.length
        )
        guard setSelectedRange(replacementRange, on: focusedElement),
              let observedRange = selectedRange(of: focusedElement),
              observedRange.location == replacementRange.location,
              observedRange.length == replacementRange.length else {
            return false
        }

        return insertViaClipboard(newText)
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

    /// Walks the AX ancestor chain looking for a web content container.
    private func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 25 {
            if role(of: candidate) == "AXWebArea" {
                return true
            }
            current = parent(of: candidate)
            depth += 1
        }
        return false
    }

    private func role(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRef
        ) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentRef
        ) == .success,
        let parentRef,
        CFGetTypeID(parentRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (parentRef as! AXUIElement)
    }

    private func textAndSelection(of element: AXUIElement) -> (String, CFRange)? {
        guard let currentValue = textValue(of: element),
              let selectedRange = selectedRange(of: element) else { return nil }
        return (currentValue, selectedRange)
    }

    private func textValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
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
        return selectedRange
    }

    @discardableResult
    private func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    /// Fallback: copy to clipboard and simulate Cmd+V
    @discardableResult
    private func insertViaClipboard(_ text: String) -> Bool {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set our text
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }
        let insertedChangeCount = pasteboard.changeCount

        // Simulate Cmd+V
        guard simulateKeyPress(keyCode: 9, flags: .maskCommand) else {
            if let previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previousContents, forType: .string)
            }
            return false
        }

        // Restore clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Do not overwrite a clipboard change the user made after dictation.
            guard pasteboard.changeCount == insertedChangeCount else { return }
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
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

    @discardableResult
    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
