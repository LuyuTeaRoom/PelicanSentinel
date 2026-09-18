import Foundation

enum AppIdentity {
    static let name = "Pelican Sentinel"
    static let dataDirectoryName = "PelicanSentinel"
    static var defaultImageSaveDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PelicanSentinel", isDirectory: true)
    }
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName)
    }
}
