import SwiftUI

/// Floating recording overlay panel
class RecordingOverlayController {
    private var window: NSPanel?
    
    @MainActor
    func show(state: TranscriptionState, modelName: String?) {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow, .titled],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            
            // Position near top-right
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - 220
                let y = screen.visibleFrame.maxY - 80
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            window = panel
        }
        
        let overlayView = RecordingOverlayContent(state: state, modelName: modelName)
        window?.contentView = NSHostingView(rootView: overlayView)
        window?.orderFrontRegardless()
    }
    
    @MainActor
    func dismiss() {
        window?.orderOut(nil)
    }
    
    @MainActor
    func dismissAfterDelay(_ seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            dismiss()
        }
    }
}

struct RecordingOverlayContent: View {
    let state: TranscriptionState
    let modelName: String?
    
    var body: some View {
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
                .fill(backgroundColor.opacity(0.9))
                .shadow(radius: 8)
        )
        .padding(8)
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
        case .processing: return "Transcribing..."
        case .done(let text): return String(text.prefix(40))
        case .error(let msg): return msg
        case .idle: return "Ready"
        }
    }
    
    private var backgroundColor: Color {
        switch state {
        case .recording: return Color(nsColor: .darkGray)
        case .processing: return Color(nsColor: .darkGray)
        case .done: return .green.opacity(0.8)
        case .error: return .red.opacity(0.8)
        case .idle: return Color(nsColor: .darkGray)
        }
    }
}
