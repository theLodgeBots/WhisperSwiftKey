import SwiftUI

@main
struct WhisperSwiftKeyApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "mic.fill" : "mic")
                .symbolEffect(.pulse, isActive: appState.isRecording)
        }
        
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
