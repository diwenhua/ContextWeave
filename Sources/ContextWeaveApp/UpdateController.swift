import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private var observation: AnyCancellable?
    private let controller: SPUStandardUpdaterController?

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
        observation = updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
