import Foundation

/// Resolves resources from the assembled TokenRemain application bundle.
///
/// `Bundle.main` is correct for a normal LaunchServices launch. During local
/// recovery or debugging, however, macOS can execute the binary inside
/// `Contents/MacOS` without promoting the enclosing `.app` to the main bundle.
/// Walking up from the executable keeps artwork and localization available in
/// that degraded launch mode without hard-coding an installation directory.
enum AppResourceBundle {
    static let bundle: Bundle = resolve()

    private static func resolve() -> Bundle {
        var candidates = [Bundle.main]
        var seenPaths = Set([Bundle.main.bundleURL.standardizedFileURL.path])

        let executableURLs = [
            Bundle.main.executableURL,
            ProcessInfo.processInfo.arguments.first.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        ].compactMap { $0 }

        for executableURL in executableURLs {
            var directory = executableURL.deletingLastPathComponent()
            while directory.path != "/" {
                if directory.pathExtension == "app",
                   seenPaths.insert(directory.standardizedFileURL.path).inserted,
                   let appBundle = Bundle(url: directory) {
                    candidates.append(appBundle)
                    break
                }
                directory.deleteLastPathComponent()
            }
        }

        return candidates.first(where: containsTokenRemainResources) ?? Bundle.main
    }

    private static func containsTokenRemainResources(_ bundle: Bundle) -> Bool {
        guard bundle.url(forResource: "claude", withExtension: "png") != nil else {
            return false
        }
        return bundle.localizations.contains { localization in
            bundle.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            ) != nil
        }
    }
}
