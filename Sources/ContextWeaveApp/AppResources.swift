import Foundation

extension Bundle {
    static let appResources: Bundle = {
        if let url = Bundle.main.url(forResource: "ContextWeave_ContextWeaveApp", withExtension: "bundle"),
           let resources = Bundle(url: url) {
            return resources
        }
        return Bundle.module
    }()
}
