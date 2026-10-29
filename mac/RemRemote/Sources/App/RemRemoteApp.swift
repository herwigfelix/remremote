import SwiftUI

@main
struct RemRemoteApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("remremote") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.permissions)
                .onAppear { state.startupAutoConnect() }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Divider()
                Button(String(localized: "Toggle remote audio")) { state.toggleAudio() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(String(localized: "Toggle clipboard sync")) { state.toggleClipboardSync() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(String(localized: "Push clipboard")) { state.pushClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(String(localized: "Send file…")) { state.sendFile() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button(String(localized: "Toggle remote speech synthesizer")) { state.toggleRemoteTTS() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(String(localized: "Disconnect")) { state.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
