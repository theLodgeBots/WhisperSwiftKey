import Cocoa
import Carbon

/// Detects global hotkey (double-tap Fn / custom combo) via CGEvent tap
class HotkeyService {
    private var eventTap: CFMachPort?
    private var onTrigger: () -> Void
    
    // Double-tap Fn detection
    private var lastFnPressTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4
    
    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
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
        
        print("[HotkeyService] Event tap active — listening for double-tap Fn")
    }
    
    private func handleEvent(_ event: CGEvent) {
        let flags = event.flags
        let isFnPressed = flags.contains(.maskSecondaryFn)
        
        // Only trigger on Fn key alone (no other modifiers)
        let otherModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty
        
        if isFnPressed && !hasOtherModifiers {
            let now = Date()
            if let lastPress = lastFnPressTime, now.timeIntervalSince(lastPress) < doubleTapThreshold {
                // Double-tap detected!
                lastFnPressTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger()
                }
            } else {
                lastFnPressTime = now
            }
        }
    }
}
