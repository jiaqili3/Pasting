import AppKit
import ImageIO

/// Downsampled image thumbnails: memory (NSCache) + disk (thumbs/), created once via CGImageSource.
final class ThumbCache {
    static let shared = ThumbCache()
    private let mem = NSCache<NSString, NSImage>()
    private let dir: URL
    private init() {
        dir = Store.shared.supportDir.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mem.countLimit = 200
        mem.totalCostLimit = 24 * 1024 * 1024   // ~24 MB of decoded thumbnails
    }

    func thumbnail(for filename: String, maxPixel: Int = 280) -> NSImage? {
        let key = filename as NSString
        if let img = mem.object(forKey: key) { return img }
        let thumbURL = dir.appendingPathComponent(filename)
        var src: CGImageSource?
        if FileManager.default.fileExists(atPath: thumbURL.path) {
            src = CGImageSourceCreateWithURL(thumbURL as CFURL, nil)
        }
        let fromCache = src != nil
        if src == nil { src = CGImageSourceCreateWithURL(Store.shared.imageURL(for: filename) as CFURL, nil) }
        guard let source = src else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        if !fromCache, let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        mem.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
        return img
    }

    func remove(_ filename: String) {
        mem.removeObject(forKey: filename as NSString)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
    }

    /// Pre-warm thumbnails off the main thread.
    func prewarm(_ filenames: [String]) {
        DispatchQueue.global(qos: .utility).async {
            for f in filenames { _ = self.thumbnail(for: f) }
        }
    }
}

/// App / file icons, looked up once.
final class IconCache {
    static let shared = IconCache()
    private var apps: [String: NSImage] = [:]
    private var files: [String: NSImage] = [:]
    private let lock = NSLock()

    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let i = apps[bundleID] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 16, height: 16)
        apps[bundleID] = i
        return i
    }

    func fileIcon(path: String?) -> NSImage? {
        guard let path else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let i = files[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        if files.count > 200 { files.removeAll() }
        files[path] = i
        return i
    }
}

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
}
