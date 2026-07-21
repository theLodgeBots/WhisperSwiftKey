import SwiftUI
import ApplicationServices
import QuartzCore

/// Floating recording overlay panel
class RecordingOverlayController {
    private var window: NSPanel?
    private var caretIndicatorWindow: NSPanel?
    private var caretFollowTask: Task<Void, Never>?
    private var dismissGeneration = 0
    private var shouldShowCaretIndicator = false
    private var targetApplicationPID: pid_t?
    private var pinnedOverlayVisibleFrame: NSRect?
    private var suppressCaretMovementUntil = Date.distantPast
    
    @MainActor
    func show(
        state: TranscriptionState,
        modelName: String?,
        previewText: String = "",
        targetApplicationPID requestedTargetApplicationPID: pid_t? = nil
    ) {
        if case .recording = state,
           !shouldShowCaretIndicator {
            // Capture the owner of the caret before ordering either overlay. Asking
            // the system-wide AX element afterward can resolve to our own panel.
            targetApplicationPID = requestedTargetApplicationPID
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            pinnedOverlayVisibleFrame = screenContainingCurrentCaret()?.visibleFrame
                ?? NSScreen.main?.visibleFrame
        }

        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isMovableByWindowBackground = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            
            window = panel
        }
        
        let overlayView = RecordingOverlayContent(
            state: state,
            modelName: modelName,
            previewText: previewText
        )
        window?.contentView = NSHostingView(rootView: overlayView)
        window?.contentView?.layoutSubtreeIfNeeded()
        positionWindow()
        window?.orderFrontRegardless()
        updateCaretIndicator(for: state)

        switch state {
        case .recording:
            startCaretFollowLoop()
        default:
            stopCaretFollowLoop()
        }
    }
    
    @MainActor
    func dismiss() {
        dismissGeneration += 1
        stopCaretFollowLoop()
        window?.orderOut(nil)
        shouldShowCaretIndicator = false
        targetApplicationPID = nil
        pinnedOverlayVisibleFrame = nil
        suppressCaretMovementUntil = .distantPast
        caretIndicatorWindow?.orderOut(nil)
    }

    /// AX text replacement can briefly report the beginning of the replaced range
    /// before the editor restores the caret to its final position. Ignore that
    /// transient sample so the microphone does not dart backward and forward.
    @MainActor
    func beginProvisionalTextReplacement() {
        suppressCaretMovementUntil = .distantFuture
    }

    /// Re-read only the final caret position after the synchronous AX edit has
    /// finished, then glide the microphone there.
    @MainActor
    func endProvisionalTextReplacement() {
        suppressCaretMovementUntil = .distantPast
        positionAndShowCaretIndicator()
    }
    
    @MainActor
    func dismissAfterDelay(_ seconds: Double) {
        dismissGeneration += 1
        let generation = dismissGeneration
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                guard self.dismissGeneration == generation else { return }
                self.dismiss()
            }
        }
    }

    @MainActor
    private func startCaretFollowLoop() {
        caretFollowTask?.cancel()
        caretFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                await MainActor.run {
                    self?.refreshCaretIndicatorPositionIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func stopCaretFollowLoop() {
        caretFollowTask?.cancel()
        caretFollowTask = nil
    }

    @MainActor
    private func refreshCaretIndicatorPositionIfNeeded() {
        if shouldShowCaretIndicator {
            positionAndShowCaretIndicator()
        }
    }

    @MainActor
    private func updateCaretIndicator(for state: TranscriptionState) {
        if case .recording = state {
            shouldShowCaretIndicator = true
            ensureCaretIndicatorWindow()
            positionAndShowCaretIndicator()
        } else {
            shouldShowCaretIndicator = false
            targetApplicationPID = nil
            caretIndicatorWindow?.orderOut(nil)
        }
    }

    @MainActor
    private func ensureCaretIndicatorWindow() {
        guard caretIndicatorWindow == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 34, height: 34),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DictationCaretIndicator())
        caretIndicatorWindow = panel
    }

    @MainActor
    private func positionAndShowCaretIndicator() {
        guard Date() >= suppressCaretMovementUntil else { return }
        guard let indicator = caretIndicatorWindow,
              let caretRect = currentCaretRectInScreenCoordinates() else {
            caretIndicatorWindow?.orderOut(nil)
            return
        }

        let size = indicator.frame.size
        let margin: CGFloat = 6
        let caretMidpoint = NSPoint(x: caretRect.midX, y: caretRect.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(caretMidpoint) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let desiredX = caretRect.midX - (size.width / 2)
        let aboveY = caretRect.maxY + margin
        let belowY = caretRect.minY - size.height - margin
        let desiredY = aboveY + size.height <= visibleFrame.maxY - 4 ? aboveY : belowY
        let origin = NSPoint(
            x: min(max(desiredX, visibleFrame.minX + 4), visibleFrame.maxX - size.width - 4),
            y: min(max(desiredY, visibleFrame.minY + 4), visibleFrame.maxY - size.height - 4)
        )

        if indicator.isVisible {
            indicator.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                indicator.animator().setFrameOrigin(origin)
            }
        } else {
            indicator.setFrameOrigin(origin)
            indicator.orderFrontRegardless()
        }
    }

    @MainActor
    private func positionWindow() {
        guard let window else { return }
        guard let visibleFrame = pinnedOverlayVisibleFrame ?? NSScreen.main?.visibleFrame else { return }

        // The transcript capsule stays fixed while the small microphone alone
        // follows the caret. This avoids the large panel jumping as lines wrap.
        let x = visibleFrame.maxX - window.frame.width - 20
        let y = visibleFrame.maxY - window.frame.height - 20
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @MainActor
    private func screenContainingCurrentCaret() -> NSScreen? {
        guard let caretRect = currentCaretRectInScreenCoordinates() else { return nil }
        let midpoint = NSPoint(x: caretRect.midX, y: caretRect.midY)
        return NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) })
    }

    @MainActor
    private func currentCaretRectInScreenCoordinates() -> CGRect? {
        guard let targetApplicationPID else { return nil }
        return Self.caretRectInScreenCoordinates(for: targetApplicationPID)
    }

    /// Internal for the focused NSTextView integration test. The returned rect is
    /// in the same AppKit screen coordinate system used to position NSPanel.
    @MainActor
    static func caretRectInScreenCoordinates(for applicationPID: pid_t) -> CGRect? {
        let focusedAppElement = AXUIElementCreateApplication(applicationPID)

        var focusedUI: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedAppElement, kAXFocusedUIElementAttribute as CFString, &focusedUI) == .success,
              let focusedUI else {
            return nil
        }
        let focusedElement = focusedUI as! AXUIElement

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let axRangeValue = selectedRangeRef,
              CFGetTypeID(axRangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = axRangeValue as! AXValue

        var caretRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &caretRange) else {
            return nil
        }
        caretRange.length = 0

        guard let caretRangeValue = AXValueCreate(.cfRange, &caretRange) else {
            return nil
        }

        var boundsRef: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            caretRangeValue,
            &boundsRef
        )
        guard result == .success,
              let axBoundsValue = boundsRef,
              CFGetTypeID(axBoundsValue) == AXValueGetTypeID() else {
            return nil
        }
        let boundsValue = axBoundsValue as! AXValue

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else {
            return nil
        }

        if rect.isNull || rect.isInfinite || rect.width < 0 || rect.height < 0 {
            return nil
        }

        // AX bounds are often top-left based; flip into AppKit screen coordinates when needed.
        if let converted = convertAXRectToAppKitCoordinates(rect) {
            return converted
        }
        return nil
    }

    @MainActor
    private static func convertAXRectToAppKitCoordinates(_ rect: CGRect) -> CGRect? {
        // Accessibility range bounds use a top-left screen origin, while AppKit
        // windows use a bottom-left origin. Convert against the primary display first.
        if let primaryScreen = NSScreen.screens.first {
            let converted = CGRect(
                x: rect.origin.x,
                y: primaryScreen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            let convertedMidpoint = NSPoint(x: converted.midX, y: converted.midY)
            if NSScreen.screens.contains(where: { $0.frame.contains(convertedMidpoint) }) {
                return converted
            }
        }

        // Some native controls already vend AppKit-style coordinates.
        let directMidpoint = NSPoint(x: rect.midX, y: rect.midY)
        if NSScreen.screens.contains(where: { $0.frame.contains(directMidpoint) }) {
            return rect
        }

        return nil
    }
}

private struct DictationCaretIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(isPulsing ? 0.12 : 0.55), lineWidth: 2)
                .scaleEffect(isPulsing ? 1.2 : 0.88)

            Circle()
                .fill(Color.black.opacity(0.86))
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .frame(width: 26, height: 26)

            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .accessibilityLabel("Dictation is listening")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

struct RecordingOverlayContent: View {
    let state: TranscriptionState
    let modelName: String?
    let previewText: String
    
    var body: some View {
        Group {
            switch state {
            case .recording:
                recordingBadge
            case .loadingModel:
                loadingBadge
            default:
                statusPanel
            }
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .fill(.red.opacity(0.5))
                        .frame(width: 20, height: 20)
                )
        case .loadingModel:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .processing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundColor(.white)
        }
    }

    private var statusText: String {
        switch state {
        case .recording: return "Dictating..."
        case .loadingModel: return "Loading model..."
        case .processing: return "Transcribing..."
        case .done(let text): return String(text.prefix(40))
        case .error(let msg): return msg
        case .idle: return "Ready"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .recording: return Color(nsColor: .darkGray)
        case .loadingModel: return Color(nsColor: .darkGray)
        case .processing: return Color(nsColor: .darkGray)
        case .done: return .green.opacity(0.8)
        case .error: return .red.opacity(0.8)
        case .idle: return Color(nsColor: .darkGray)
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                if let model = modelName {
                    Text(model)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .padding(8)
    }

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.22))
                    .frame(width: 24, height: 24)
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dictating")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                if !previewText.isEmpty {
                    Text(previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: 310, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        )
        .padding(6)
    }

    private var loadingBadge: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Loading model...")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        )
        .padding(6)
    }
}

// MARK: - Model Loading Overlay (Full-screen centered panel)

class ModelLoadingOverlayController {
    private var window: NSPanel?

    @MainActor
    func show(modelDisplayName: String, progress: Double, phase: String, storagePath: String) {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isMovableByWindowBackground = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false

            window = panel
        }

        let content = ModelLoadingOverlayContent(
            modelDisplayName: modelDisplayName,
            progress: progress,
            phase: phase,
            storagePath: storagePath
        )
        window?.contentView = NSHostingView(rootView: content)
        window?.contentView?.layoutSubtreeIfNeeded()
        centerOnScreen()
        window?.orderFrontRegardless()
    }

    @MainActor
    func dismiss() {
        window?.orderOut(nil)
    }

    @MainActor
    private func centerOnScreen() {
        guard let window, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - window.frame.width / 2
        let y = screenFrame.midY - window.frame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct ModelLoadingOverlayContent: View {
    let modelDisplayName: String
    let progress: Double
    let phase: String
    let storagePath: String

    var body: some View {
        VStack(spacing: 16) {
            // Model name
            Text(modelDisplayName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            // Progress bar with percentage
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)

                HStack {
                    Text(phase)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            // Storage path (truncated caption)
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(storagePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
        }
        .padding(28)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        )
    }
}
