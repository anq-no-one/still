#if os(macOS)
import Foundation
import Observation
import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
    var isEnabled: Bool { get }
    func enable() throws
    func disable() throws
}

@MainActor
@Observable
final class LaunchAtLogin {
    private let service: LoginItemService

    private(set) var isEnabled: Bool
    private(set) var problem: String?

    init(service: LoginItemService) {
        self.service = service
        isEnabled = service.isEnabled
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try service.enable()
            } else {
                try service.disable()
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        isEnabled = service.isEnabled
    }
}

@MainActor
final class MainAppLoginItem: LoginItemService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func enable() throws {
        try SMAppService.mainApp.register()
    }

    func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
#endif
