import Foundation
import ServiceManagement
import AppKit

enum LoginItem {
    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    AppLog.info("SMAppService registered for login")
                } else {
                    try SMAppService.mainApp.unregister()
                    AppLog.info("SMAppService unregistered")
                }
                // Clean up any LaunchAgent fallback
                removeLaunchAgent()
                return
            } catch {
                AppLog.error("SMAppService failed (\(error)); falling back to LaunchAgent")
            }
        }
        if enabled {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    static func isEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            if status == .enabled { return true }
        }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.jiaqili.pasting.plist")
    }

    private static func installLaunchAgent() {
        let appPath = Bundle.main.bundleURL.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.jiaqili.pasting</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            AppLog.info("Installed LaunchAgent at \(launchAgentURL.path)")
        } catch {
            AppLog.error("Failed to install LaunchAgent: \(error)")
        }
    }

    private static func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: launchAgentURL)
    }
}
