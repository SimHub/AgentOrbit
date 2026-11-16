import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var requiresApproval: Bool = false

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        guard isAppBundle else {
            isEnabled = false
            requiresApproval = false
            return
        }
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    func setEnabled(_ enabled: Bool) {
        guard isAppBundle else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Keep UI synchronized with actual OS state
        }
        refreshStatus()
    }
}
