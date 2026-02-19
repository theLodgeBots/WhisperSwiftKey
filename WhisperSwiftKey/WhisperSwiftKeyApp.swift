import SwiftUI

@main
struct WhisperSwiftKeyApp: App {
    @StateObject private var appState = AppState()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    
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
        
        // Onboarding window
        Window("Welcome to WhisperSwiftKey", id: "onboarding") {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
