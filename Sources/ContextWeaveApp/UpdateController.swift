import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private var observations: [AnyCancellable] = []
    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init() {
        // SwiftPM executables run outside an app bundle. Sparkle needs bundle metadata.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            controller = nil
            return
        }
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        controller = updaterController
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        observations = [
            updaterController.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    MainActor.assumeIsolated { self?.canCheckForUpdates = value }
                },
            updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
                }
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
    }
}
