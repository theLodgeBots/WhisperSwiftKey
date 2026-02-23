import SwiftUI
import ApplicationServices

/// Floating recording overlay panel
class RecordingOverlayController {
    private var window: NSPanel?
    private var caretFollowTask: Task<Void, Never>?
    private var dismissGeneration = 0
    
    @MainActor
    func show(state: TranscriptionState, modelName: String?) {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
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
        
        let overlayView = RecordingOverlayContent(state: state, modelName: modelName)
        window?.contentView = NSHostingView(rootView: overlayView)
        window?.contentView?.layoutSubtreeIfNeeded()
        positionWindow(for: state)
        window?.orderFrontRegardless()

        switch state {
        case .recording, .loadingModel:
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
                    self?.refreshCaretAnchoredPositionIfNeeded()
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
    private func refreshCaretAnchoredPositionIfNeeded() {
        guard let window else { return }
        guard window.isVisible else { return }
        if let origin = caretAnchoredOrigin(for: window.frame.size) {
            window.setFrameOrigin(origin)
        }
    }

    @MainActor
    private func positionWindow(for state: TranscriptionState) {
        guard let window else { return }

        switch state {
        case .recording, .loadingModel:
            if let origin = caretAnchoredOrigin(for: window.frame.size) {
                window.setFrameOrigin(origin)
                return
            }
        default:
            break
        }

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - window.frame.width - 20
            let y = screen.visibleFrame.maxY - window.frame.height - 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    @MainActor
    private func caretAnchoredOrigin(for overlaySize: NSSize) -> NSPoint? {
        guard let rect = currentCaretRectInScreenCoordinates() else { return nil }
        let margin: CGFloat = 10
        let desiredX = rect.maxX + margin
        let desiredY = rect.midY - (overlaySize.height / 2)

        let candidate = NSPoint(x: desiredX, y: desiredY)
        return clampToVisibleScreen(candidate, overlaySize: overlaySize)
    }

    @MainActor
    private func clampToVisibleScreen(_ origin: NSPoint, overlaySize: NSSize) -> NSPoint {
        let directPoint = NSPoint(x: origin.x + overlaySize.width / 2, y: origin.y + overlaySize.height / 2)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(directPoint) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }

        let clampedX = min(max(origin.x, visible.minX + 8), visible.maxX - overlaySize.width - 8)
        let clampedY = min(max(origin.y, visible.minY + 8), visible.maxY - overlaySize.height - 8)
        return NSPoint(x: clampedX, y: clampedY)
    }

    @MainActor
    private func currentCaretRectInScreenCoordinates() -> CGRect? {
        let system = AXUIElementCreateSystemWide()

        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let focusedApp else {
            return nil
        }
        let focusedAppElement = focusedApp as! AXUIElement

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
        return rect
    }

    @MainActor
    private func convertAXRectToAppKitCoordinates(_ rect: CGRect) -> CGRect? {
        // If rect already appears in a visible screen region, keep it as-is.
        let directMid = NSPoint(x: rect.midX, y: rect.midY)
        if NSScreen.screens.contains(where: { $0.frame.contains(directMid) }) {
            return rect
        }

        for screen in NSScreen.screens {
            let flippedY = screen.frame.maxY - rect.origin.y - rect.height
            let candidate = CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
            let mid = NSPoint(x: candidate.midX, y: candidate.midY)
            if screen.frame.contains(mid) {
                return candidate
            }
        }

        return nil
    }
}

struct RecordingOverlayContent: View {
    let state: TranscriptionState
    let modelName: String?
    
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

            Text("Dictating")
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
