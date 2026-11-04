import Foundation

/// Runtime data lives in Application Support so the app never needs macOS
/// "Desktop folder" permission, even though the project itself sits on the
/// Desktop for easy access.
let supportDirectory: URL = {
    FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MonkeWall", isDirectory: true)
}()

let configURL = supportDirectory.appendingPathComponent("config.json")

let logURL = FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs", isDirectory: true)
    .appendingPathComponent("MonkeWall.log")

private let logLock = NSLock()

func appLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }

    logLock.lock()
    defer { logLock.unlock() }

    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL, options: .atomic)
    }
}
