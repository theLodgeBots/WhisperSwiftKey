import Cocoa
import Carbon

/// Detects global hotkey (double-tap Fn or push-to-talk) via CGEvent tap
class HotkeyService {
    private var eventTap: CFMachPort?
    private var onToggle: () -> Void // For tap-to-toggle: fires on double-tap
    var onPushStart: (() -> Void)?   // For push-to-talk: fires on key down
    var onPushStop: (() -> Void)?    // For push-to-talk: fires on key up
    
    var mode: HotkeyMode = .doubleTap
    
    enum HotkeyMode {
        case doubleTap    // Double-tap Fn toggles recording
        case pushToTalk   // Hold Fn to record, release to stop
    }
    
    // Double-tap detection
    private var lastFnPressTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4
    
    // Push-to-talk state
    private var isFnHeld = false
    
    init(onTrigger: @escaping () -> Void) {
        self.onToggle = onTrigger
        setupEventTap()
    }
    
    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
    
    private func setupEventTap() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
            service.handleEvent(event)
            return Unmanaged.passRetained(event)
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            print("[HotkeyService] Failed to create event tap — Accessibility permission needed")
            return
        }
        
        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        print("[HotkeyService] Event tap active")
    }
    
    private func handleEvent(_ event: CGEvent) {
        let flags = event.flags
        let isFnPressed = flags.contains(.maskSecondaryFn)
        
        // Only trigger on Fn key alone (no other modifiers)
        let otherModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty
        guard !hasOtherModifiers else { return }
        
        switch mode {
        case .doubleTap:
            if isFnPressed {
                let now = Date()
                if let lastPress = lastFnPressTime, now.timeIntervalSince(lastPress) < doubleTapThreshold {
                    lastFnPressTime = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggle()
                    }
                } else {
                    lastFnPressTime = now
                }
            }
            
        case .pushToTalk:
            if isFnPressed && !isFnHeld {
                isFnHeld = true
                DispatchQueue.main.async { [weak self] in
                    self?.onPushStart?()
                }
            } else if !isFnPressed && isFnHeld {
                isFnHeld = false
                DispatchQueue.main.async { [weak self] in
                    self?.onPushStop?()
                }
            }
        }
    }
}
