import Foundation
import AppKit

enum ClipKind: String, Codable, CaseIterable {
    case text
    case url
    case image
    case file
    case color
}

struct ClipItem: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ClipKind
    var createdAt: Date
    var text: String?
    var urlString: String?
    var imageFilename: String?
    var fileURLs: [String]?
    var colorHex: String?
    var rtfData: Data?
    var htmlData: Data?
    var customTitle: String?
    var sourceAppName: String?
    var sourceAppBundleID: String?
    var pinboardIDs: [UUID]
    /// Legacy (≤1.0): migrated into `favorite` on load.
    var isPinned: Bool?
    var favorite: Bool?
    var isFavorite: Bool {
        get { favorite ?? false }
        set { favorite = newValue ? true : nil }
    }

    init(
        id: UUID = UUID(),
        kind: ClipKind,
        createdAt: Date = Date(),
        text: String? = nil,
        urlString: String? = nil,
        imageFilename: String? = nil,
        fileURLs: [String]? = nil,
        colorHex: String? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        customTitle: String? = nil,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        pinboardIDs: [UUID] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.text = text
        self.urlString = urlString
        self.imageFilename = imageFilename
        self.fileURLs = fileURLs
        self.colorHex = colorHex
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.customTitle = customTitle
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.pinboardIDs = pinboardIDs
        self.favorite = isFavorite ? true : nil
    }

    var isRich: Bool { rtfData != nil || htmlData != nil }

    /// Plain text with all formatting stripped.
    var plainText: String? {
        if let text, !text.isEmpty { return text }
        return RichText.plainText(rtf: rtfData, html: htmlData) ?? urlString
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        switch kind {
        case .text:
            let t = text ?? ""
            return t.count > 80 ? String(t.prefix(80)) + "…" : t
        case .url:
            return urlString ?? text ?? "Link"
        case .image:
            return "Image"
        case .file:
            if let first = fileURLs?.first {
                return URL(fileURLWithPath: first).lastPathComponent
            }
            return "File"
        case .color:
            return colorHex ?? "Color"
        }
    }

    var searchableText: String {
        [
            customTitle,
            text,
            urlString,
            colorHex,
            sourceAppName,
            fileURLs?.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    func contentFingerprint() -> String {
        switch kind {
        case .text, .url, .color:
            return "\(kind.rawValue)|\(text ?? "")|\(urlString ?? "")|\(colorHex ?? "")"
        case .image:
            return "\(kind.rawValue)|\(imageFilename ?? "")|\(text ?? "")"
        case .file:
            return "\(kind.rawValue)|\((fileURLs ?? []).sorted().joined(separator: ";"))"
        }
    }
}

struct Pinboard: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct AppSettings: Codable, Equatable {
    var favoritesMigrated: Bool?
    var openAtLogin: Bool
    var capturingPaused: Bool
    var historyLimit: Int
    var hasCompletedOnboarding: Bool
    /// History retention in days; 0 = forever; nil (old store files) = 7.
    var retentionDays: Int?
    var effectiveRetentionDays: Int { retentionDays ?? 7 }
    /// "system" | "zh" | "en"
    var language: String?
    var ignoreConcealed: Bool?
    var ignoredApps: [String]?
    var panelWidth: Double?
    var cardSize: Double?
    var effectivePanelWidth: CGFloat { CGFloat(panelWidth ?? 560) }
    var effectiveCardSize: CGFloat { CGFloat(cardSize ?? 120) }
    var languageChoice: L10n.Choice { L10n.Choice(rawValue: language ?? "system") ?? .system }

    static let `default` = AppSettings(
        openAtLogin: false,
        capturingPaused: false,
        historyLimit: 500,
        hasCompletedOnboarding: false,
        retentionDays: 7
    )
}

struct PersistedStore: Codable {
    var items: [ClipItem]
    var pinboards: [Pinboard]
    var settings: AppSettings
}


enum RichText {
    static func plainText(rtf: Data?, html: Data?) -> String? {
        if let rtf, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return a.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let html, let a = NSAttributedString(html: html, documentAttributes: nil) {
            return a.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Startup self-test: HTML <b>bold</b> -> RTF -> plain text must be "bold".
    static func selfTest() {
        guard let a = NSAttributedString(html: Data("<b>bold</b>".utf8), documentAttributes: nil),
              let rtf = a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:]) else {
            AppLog.error("RichText self-test: could not build RTF"); return
        }
        let out = plainText(rtf: rtf, html: nil) ?? "nil"
        if out == "bold" { AppLog.info("RichText self-test PASS (rtf -> \"\(out)\")") }
        else { AppLog.error("RichText self-test FAIL (got \"\(out)\")") }
    }
}


enum SearchIndex {
    /// Normalized search key: lowercased, diacritic/width-folded, capped at 2000 chars.
    static func key(for item: ClipItem) -> String {
        var parts: [String] = []
        if let s = item.customTitle { parts.append(s) }
        if let s = item.text { parts.append(String(s.prefix(2000))) }
        if let s = item.urlString { parts.append(s) }
        if let s = item.colorHex { parts.append(s) }
        if let s = item.sourceAppName { parts.append(s) }
        if let f = item.fileURLs { parts.append(f.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " ")) }
        return normalize(parts.joined(separator: " "))
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func filter(_ items: [ClipItem], keys: [UUID: String], query: String) -> [ClipItem] {
        let q = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if q.isEmpty { return items }
        let terms = q.split(separator: " ").map(String.init)
        return items.filter { it in
            guard let k = keys[it.id] else { return false }
            return terms.allSatisfy { k.contains($0) }
        }
    }
}
