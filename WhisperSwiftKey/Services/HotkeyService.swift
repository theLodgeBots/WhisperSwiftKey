import Cocoa
import Carbon

struct HotkeyInputObservation {
    let typeRawValue: UInt32
    let keyCode: Int64
    let flagsRawValue: UInt64
    let fnFlag: Bool
    let timestamp: Date
}

/// Detects global hotkey (double-tap Fn or push-to-talk) via CGEvent tap
class HotkeyService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapLocation: CGEventTapLocation?
#if DEBUG
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
#endif
    private var onToggle: () -> Void // For tap-to-toggle: fires on double-tap
    var onInputObservation: ((HotkeyInputObservation) -> Void)?
    var onPushStart: (() -> Void)?   // For push-to-talk: fires on key down
    var onPushStop: (() -> Void)?    // For push-to-talk: fires on key up
    
    var mode: HotkeyMode = .doubleTap
    private(set) var isEventTapActive = false

#if DEBUG
    private static let verboseKeyLoggingEnabled = ProcessInfo.processInfo.environment["WSK_HOTKEY_DEBUG"] == "1"
#endif
    
    enum HotkeyMode {
        case doubleTap    // Double-tap Fn toggles recording
        case pushToTalk   // Hold Fn to record, release to stop
    }
    
    // Double-tap detection
    private var lastFnPressTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.65

    // Push-to-talk state
    private var isFnHeld = false
    private var lastObservedFnPressed = false
    private var lastSystemDefinedGlobePulseAt: Date?
    private var lastRegisteredGlobePressAt: Date?
    private var hasObservedReliableGlobeFnEvents = false
    private let samePhysicalPressDedupThreshold: TimeInterval = 0.12
    
    init(onTrigger: @escaping () -> Void) {
        self.onToggle = onTrigger
        installDebugEventMonitorsIfNeeded()
        setupEventTap()
    }
    
    deinit {
        tearDownEventTap()
        removeDebugEventMonitorsIfNeeded()
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func reinitializeEventTapIfNeeded() {
        guard !isEventTapActive else { return }
        setupEventTap()
    }
    
    private func setupEventTap() {
        guard Self.hasAccessibilityPermission() else {
            isEventTapActive = false
            print("[HotkeyService] Failed to create event tap — Accessibility permission needed")
            return
        }

        tearDownEventTap()

        let eventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << 14) // NX_SYSDEFINED / "systemDefined" (media/Globe keys on some Macs)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = service.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    service.isEventTapActive = true
                    print("[HotkeyService] Event tap re-enabled after system disabled it (\(type.rawValue))")
                }
                return Unmanaged.passUnretained(event)
            }
            service.emitInputObservation(event, type: type)
            #if DEBUG
            if HotkeyService.verboseKeyLoggingEnabled {
                service.debugLogCGEvent(event, type: type)
            }
            #endif

            guard type == .flagsChanged || type == .keyDown || type == .keyUp else {
                if type.rawValue == 14 {
                    service.handleEvent(event, type: type)
                }
                return Unmanaged.passUnretained(event)
            }
            service.handleEvent(event, type: type)
            return Unmanaged.passUnretained(event)
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let candidateLocations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]
        var createdTap: CFMachPort?
        var createdLocation: CGEventTapLocation?
        for location in candidateLocations {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: selfPtr
            ) {
                createdTap = tap
                createdLocation = location
                break
            }
        }

        guard let tap = createdTap else {
            isEventTapActive = false
            print("[HotkeyService] Failed to create event tap — Accessibility permission needed")
            return
        }

        eventTap = tap
        eventTapLocation = createdLocation
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isEventTapActive = true
        lastObservedFnPressed = false
        lastFnPressTime = nil
        isFnHeld = false
        lastSystemDefinedGlobePulseAt = nil
        lastRegisteredGlobePressAt = nil
        hasObservedReliableGlobeFnEvents = false
        
        if let location = createdLocation {
            print("[HotkeyService] Event tap active (\(Self.tapLocationName(location)))")
        } else {
            print("[HotkeyService] Event tap active")
        }
    }
    
    private func handleEvent(_ event: CGEvent, type: CGEventType) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isFnPressed = flags.contains(.maskSecondaryFn)

        if type.rawValue == 14 {
            handleSystemDefinedGlobePulseIfNeeded(event: event)
            return
        }

        let globePressedState: Bool?
        switch type {
        case .keyDown where keyCode == 63:
            globePressedState = true
        case .keyUp where keyCode == 63:
            globePressedState = false
        case .flagsChanged:
            // Primary path on many Macs: Globe/Fn emits a modifier flag transition.
            // We only care if this looks like the Globe/Fn key or an Fn modifier transition.
            guard keyCode == 63 || isFnPressed || lastObservedFnPressed else { return }
            globePressedState = isFnPressed
        default:
            return
        }

        guard let isGlobePressed = globePressedState else { return }

        // Deduplicate repeated events (and mixed keyDown/flagsChanged duplicates) with the same state.
        guard isGlobePressed != lastObservedFnPressed else { return }
        lastObservedFnPressed = isGlobePressed

        // Some keyboards/macOS versions don't report Fn/Globe as keycode 63 in CGEvent taps.
        // We prefer the physical Globe/Fn key (keyCode 63) and fall back to the Fn modifier flag.
        #if DEBUG
        if Self.verboseKeyLoggingEnabled {
            print("[HotkeyService] Globe/Fn edge \(isGlobePressed ? "down" : "up") via=\(Self.cgEventTypeName(type)) keyCode=\(keyCode) fnFlag=\(isFnPressed)")
        }
        #endif

        // This Mac provides reliable Globe/Fn modifier transitions, so systemDefined pulses become noise.
        if keyCode == 63 || isFnPressed {
            hasObservedReliableGlobeFnEvents = true
        }
        
        // Only trigger on Globe/Fn alone (no other modifiers)
        let otherModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty
        guard !hasOtherModifiers else { return }
        
        switch mode {
        case .doubleTap:
            if isGlobePressed {
                registerGlobePressForDoubleTap()
            }
            
        case .pushToTalk:
            if isGlobePressed && !isFnHeld {
                isFnHeld = true
                DispatchQueue.main.async { [weak self] in
                    self?.onPushStart?()
                }
            } else if !isGlobePressed && isFnHeld {
                isFnHeld = false
                DispatchQueue.main.async { [weak self] in
                    self?.onPushStop?()
                }
            }
        }
    }

    private func handleSystemDefinedGlobePulseIfNeeded(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // On some Macs, Globe/Fn appears as NX_SYSDEFINED with no keycode/fn modifier.
        guard keyCode == 0 else { return }
        guard flags.rawValue == 0 else { return }

        // If we already receive reliable Globe/Fn modifier events on this machine/session,
        // systemDefined pulses are duplicate/noisy and should not count as hotkey presses.
        guard !hasObservedReliableGlobeFnEvents else { return }

        let now = Date()
        // A single physical press can emit a burst of systemDefined events. Collapse the burst.
        if let lastPulse = lastSystemDefinedGlobePulseAt,
           now.timeIntervalSince(lastPulse) < 0.18 {
            return
        }
        lastSystemDefinedGlobePulseAt = now

        #if DEBUG
        if Self.verboseKeyLoggingEnabled {
            print("[HotkeyService] Globe/Fn pulse via=systemDefined")
        }
        #endif

        switch mode {
        case .doubleTap:
            registerGlobePressForDoubleTap(now: now, source: "systemDefined")
        case .pushToTalk:
            // systemDefined Globe/Fn events are pulse-like and don't provide reliable down/up semantics
            return
        }
    }

    private func registerGlobePressForDoubleTap(now: Date = Date(), source: String = "modifier") {
        if let lastPhysicalPress = lastRegisteredGlobePressAt,
           now.timeIntervalSince(lastPhysicalPress) < samePhysicalPressDedupThreshold {
            return
        }
        lastRegisteredGlobePressAt = now

        if let lastPress = lastFnPressTime, now.timeIntervalSince(lastPress) < doubleTapThreshold {
            lastFnPressTime = nil
            #if DEBUG
            if source == "systemDefined" {
                if Self.verboseKeyLoggingEnabled {
                    print("[HotkeyService] Double-tap Globe/Fn detected (systemDefined)")
                }
            } else {
                print("[HotkeyService] Double-tap Globe/Fn detected")
            }
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.onToggle()
            }
        } else {
            lastFnPressTime = now
        }
    }

    private func tearDownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        eventTapLocation = nil
        isEventTapActive = false
    }

    private func emitInputObservation(_ event: CGEvent, type: CGEventType) {
        let observation = HotkeyInputObservation(
            typeRawValue: type.rawValue,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flagsRawValue: event.flags.rawValue,
            fnFlag: event.flags.contains(.maskSecondaryFn),
            timestamp: Date()
        )
        onInputObservation?(observation)
    }

#if DEBUG
    private func installDebugEventMonitorsIfNeeded() {
        guard Self.verboseKeyLoggingEnabled else { return }
        guard globalEventMonitor == nil, localEventMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .systemDefined]

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.debugLogNSEvent(event, scope: "global")
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.debugLogNSEvent(event, scope: "local")
            return event
        }

        print("[HotkeyService] Debug NSEvent monitors active")
    }

    private func removeDebugEventMonitorsIfNeeded() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func debugLogCGEvent(_ event: CGEvent, type: CGEventType) {
        guard Self.verboseKeyLoggingEnabled else { return }
        let isSystemDefined = type.rawValue == 14
        guard type == .flagsChanged || type == .keyDown || type == .keyUp || isSystemDefined else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasFnFlag = flags.contains(.maskSecondaryFn)

        // Keep this broad while debugging Globe/Fn behavior; all modifier changes are useful.
        if type != .flagsChanged && !isSystemDefined && keyCode != 63 && !hasFnFlag {
            return
        }

        let tapName = eventTapLocation.map(Self.tapLocationName) ?? "unknown"
        let sourceStateID = event.getIntegerValueField(.eventSourceStateID)
        print("[HotkeyDebug CGEvent] tap=\(tapName) type=\(Self.cgEventTypeName(type)) rawType=\(type.rawValue) keyCode=\(keyCode) fnFlag=\(hasFnFlag) flags=0x\(String(flags.rawValue, radix: 16)) srcState=\(sourceStateID)")
    }

    private func debugLogNSEvent(_ event: NSEvent, scope: String) {
        guard Self.verboseKeyLoggingEnabled else { return }
        let isFlags = event.type == .flagsChanged
        let isSystemDefined = event.type == .systemDefined
        let hasFunctionModifier = event.modifierFlags.contains(.function)
        let keyCode = isSystemDefined ? nil : Int(event.keyCode)

        // Log all modifier changes, and any events that look related to Fn/Globe.
        if !isFlags && !isSystemDefined && keyCode != 63 && !hasFunctionModifier {
            return
        }

        let relevantModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift, .capsLock])
        if isSystemDefined {
            print("[HotkeyDebug NSEvent \(scope)] type=systemDefined subtype=\(event.subtype.rawValue) data1=0x\(String(event.data1, radix: 16)) data2=0x\(String(event.data2, radix: 16)) mods=\(relevantModifiers) raw=0x\(String(event.modifierFlags.rawValue, radix: 16))")
        } else {
            print("[HotkeyDebug NSEvent \(scope)] type=\(Self.nsEventTypeName(event.type)) keyCode=\(keyCode ?? -1) mods=\(relevantModifiers) raw=0x\(String(event.modifierFlags.rawValue, radix: 16))")
        }
    }

    private static func cgEventTypeName(_ type: CGEventType) -> String {
        switch type {
        case .flagsChanged: return "flagsChanged"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .tapDisabledByTimeout: return "tapDisabledByTimeout"
        case .tapDisabledByUserInput: return "tapDisabledByUserInput"
        default: return "other(\(type.rawValue))"
        }
    }

    private static func nsEventTypeName(_ type: NSEvent.EventType) -> String {
        switch type {
        case .flagsChanged: return "flagsChanged"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        default: return "\(type.rawValue)"
        }
    }
#else
    private func installDebugEventMonitorsIfNeeded() {}
    private func removeDebugEventMonitorsIfNeeded() {}
#endif

    private static func tapLocationName(_ location: CGEventTapLocation) -> String {
        switch location {
        case .cgSessionEventTap:
            return "cgSessionEventTap"
        case .cghidEventTap:
            return "cghidEventTap"
        case .cgAnnotatedSessionEventTap:
            return "cgAnnotatedSessionEventTap"
        @unknown default:
            return "unknown"
        }
    }
}
