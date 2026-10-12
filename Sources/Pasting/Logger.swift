import Foundation
import os.log

enum AppLog {
    private static let logger = Logger(subsystem: "com.jiaqili.pasting", category: "app")
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(ProcessInfo.processInfo.environment["PASTING_DATA_DIR"] != nil ? "Pasting-test.log" : "Pasting.log")
    }()
    private static let queue = DispatchQueue(label: "com.jiaqili.pasting.log")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
    }

    private static func append(_ line: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let text = "[\(stamp)] \(line)\n"
            if let data = text.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }
}
