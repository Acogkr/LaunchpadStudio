import Foundation

func makeUpdatePreview() -> UpdateChecker {
    let domain = Bundle.main.bundleIdentifier! + ".updates-preview"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    let scenario = Bundle.main.object(forInfoDictionaryKey: "StudioPreviewUpdateCase") as? String
    return UpdateChecker(
        defaults: defaults,
        loader: { completion in
            switch scenario {
            case "available": completion(.success(AppRelease("v1.2.0")))
            case "offline": completion(.failure(.offline))
            case "current": completion(.success(AppRelease(AppVersion.current)))
            default: completion(.success(nil))
            }
        })
}
