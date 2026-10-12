import Foundation
import AppKit
import ApplicationServices

enum Paster {
    static func writeToPasteboard(_ item: ClipItem, plainText: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if plainText, let s = item.plainText {
            pb.setString(s, forType: .string)   // only plain string, no RTF/HTML
            return
        }

        switch item.kind {
        case .text:
            if let text = item.plainText {
                pb.setString(text, forType: .string)
            }
            if let rtf = item.rtfData { pb.setData(rtf, forType: .rtf) }
            if let html = item.htmlData { pb.setData(html, forType: .html) }
        case .url:
            let s = item.urlString ?? item.text ?? ""
            pb.setString(s, forType: .string)
            if let url = URL(string: s) {
                pb.writeObjects([url as NSURL])
            }
        case .image:
            if let name = item.imageFilename,
               let image = Store.shared.loadImage(filename: name) {
                pb.writeObjects([image])
                if let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .file:
            if let paths = item.fileURLs {
                // If it's a single image file we can read, prefer writing image data
                // (file URLs inside other apps' containers often aren't openable elsewhere).
                if paths.count == 1, let path = paths.first {
                    let url = URL(fileURLWithPath: path)
                    if ClipboardMonitor.isImageFileURL(url),
                       let image = NSImage(contentsOf: url) {
                        pb.writeObjects([image])
                        if let tiff = image.tiffRepresentation {
                            pb.setData(tiff, forType: .tiff)
                        }
                        break
                    }
                }
                let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
                pb.writeObjects(urls)
            }
        case .color:
            if let hex = item.colorHex ?? item.text {
                pb.setString(hex, forType: .string)
                if let color = NSColor.fromHex(hex) {
                    if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                        pb.setData(data, forType: NSPasteboard.PasteboardType("com.apple.cocoa.pasteboard.color"))
                    }
                }
            }
        }
    }

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func paste(item: ClipItem, into app: NSRunningApplication?, plainText: Bool = false) {
        writeToPasteboard(item, plainText: plainText)
        AppLog.info(plainText ? "Paste as plain text" : "Paste")

        guard isAccessibilityTrusted(prompt: true) else {
            AppLog.error("Accessibility not granted; content left on clipboard for manual Cmd+V")
            AccessibilityPrompt.shared.show()
            app?.activate()
            return
        }

        app?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            synthesizeCommandV()
        }
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 9 // V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            AppLog.error("Failed to create CGEvent for Cmd+V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        AppLog.info("Synthesized Cmd+V")
    }
}

final class AccessibilityPrompt {
    static let shared = AccessibilityPrompt()

    func show() {
        let alert = NSAlert()
        alert.messageText = L("需要辅助功能权限")
        alert.informativeText = L("AX_ALERT_BODY")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("打开系统设置"))
        alert.addButton(withTitle: L("稍后"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AccessibilityHelper.shared.start()
        }

    }
}
