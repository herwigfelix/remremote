import SwiftUI

/// Onboarding gate shown before the first connection until the required permissions are
/// granted. Accessibility is mandatory (no connection without it); Screen Recording is
/// required only to let this Mac be controlled (its audio streamed), so it is strongly
/// recommended but does not block controlling others.
struct PermissionsView: View {
    @EnvironmentObject private var permissions: Permissions
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Before you connect")
                .font(.title2).bold()
            Text("remremote needs these permissions. Grant them in System Settings, then return here — the checkmarks update automatically.")
                .foregroundStyle(.secondary)

            permissionRow(
                granted: permissions.accessibility,
                title: String(localized: "Accessibility"),
                detail: String(localized: "Required — to send keystrokes to the remote computer, and to receive them when this Mac is controlled."),
                action: { permissions.requestAccessibility() }
            )
            Text("When this Mac is controlled, it streams its system audio (including VoiceOver) to the controller. macOS asks for audio-recording permission automatically the first time that happens — no Screen Recording is needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(String(localized: "Continue")) { onContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.canConnect)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private func permissionRow(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel(granted ? String(localized: "granted") : String(localized: "not granted"))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(String(localized: "Grant…"), action: action)
            }
        }
    }
}
