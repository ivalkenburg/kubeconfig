import Foundation
import KubeConfigCore

struct LaunchOptions {
    let configurationURL: URL?
    let captureDirectory: URL?

    init(arguments: [String]) throws {
        var configuration: URL?
        var capture: URL?
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard option == "--config" || option == "--capture-dir" else { index += 1; continue }
            guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("--") else {
                throw ConfigError.invalid("\(option) requires a path.")
            }
            let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
            if option == "--config" { configuration = url } else { capture = url }
            index += 2
        }
        if capture != nil && configuration == nil {
            throw ConfigError.invalid("Capturing the UI requires an explicit --config sample file.")
        }
        configurationURL = configuration
        captureDirectory = capture
    }
}
