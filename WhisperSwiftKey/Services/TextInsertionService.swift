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
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier ?? ""
        
        if terminalBundleIDs.contains(bundleID) {
            insertViaClipboard(text)
        } else if !insertViaAccessibility(text) {
            insertViaClipboard(text)
        }
    }
    
    /// Try inserting via Accessibility API (preferred — doesn't touch clipboard)
    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let systemElement = AXUIElementCreateSystemWide() as AXUIElement?,
              let focusedElement = getFocusedElement(systemElement) else {
            return false
        }
        
        let value = text as CFTypeRef
        let result = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, value)
        return result == .success
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
