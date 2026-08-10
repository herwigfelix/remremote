import AppKit
import CoreGraphics
import Combine

/// The TCC (privacy) permissions remremote needs, collected before the first connection.
///
/// * Accessibility — to capture the keyboard (when controlling) and to inject keys (when
///   being controlled). Requested via the Accessibility API; granting requires a restart
///   of the permission check, so we poll.
///
/// System-audio capture (when this Mac is controlled) uses the Core Audio process-tap API,
/// which asks for its own audio permission the first time it runs — there is no Screen
/// Recording requirement, so nothing needs to be collected here for it.
@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var accessibility = false

    private var timer: Timer?

    init() {
        refresh()
    }

    /// The minimum to connect at all (control a remote machine, or be controlled).
    var canConnect: Bool { accessibility }

    func refresh() {
        accessibility = AXIsProcessTrusted()
    }

    /// Poll while an onboarding screen is visible, since granting a permission in System
    /// Settings does not call back into the app.
    func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(pane: "Privacy_Accessibility")
    }

    private func openSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
