import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the rest of the app can register or
/// unregister InputConfig as a login item with a simple toggle. Apple
/// added this API in macOS 13. The user can also turn the setting on or
/// off from System Settings > General > Login Items, and we observe that
/// state on launch.
@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()

    @Published private(set) var isEnabled: Bool
    @Published var lastError: String?
    /// Registered, but macOS is waiting for the user to allow it in
    /// System Settings, General, Login Items. The switch used to flip back
    /// off with no word about why.
    @Published private(set) var needsApproval = false

    private init() {
        self.isEnabled = (SMAppService.mainApp.status == .enabled)
        self.needsApproval = (SMAppService.mainApp.status == .requiresApproval)
    }

    /// Open System Settings at Login Items, where the approval is given.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Toggle the registration. Returns true on success, false on error.
    /// The error message is stored in `lastError` for the UI to surface.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // Re-read the actual status. macOS may put us in `.requiresApproval`
            // if the user has denied background tasks, in which case the toggle
            // visually flips but the system Settings panel shows the truth.
            refresh()
            return true
        } catch {
            refresh()
            // Waiting for approval in Login Items: the hint with its button
            // says what to do, not the raw error.
            lastError = needsApproval ? nil : error.localizedDescription
            return false
        }
    }

    /// Refresh the in-memory status from the system. Useful to call when
    /// the Settings window reopens, in case the user toggled the setting
    /// externally.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        needsApproval = (status == .requiresApproval)
    }
}
