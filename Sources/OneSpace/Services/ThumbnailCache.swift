import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Disk + memory thumbnails for image files.
/// Files live in Application Support/OneSpace/thumbs. The cache key includes path, mtime, and pixel size.
final class ThumbnailCache: @unchecked Sendable {
    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()
    private let lock = NSLock()

    init() {
        let dir: URL
        if let support = try? OneSpaceSupport.directory() {
            dir = support.appendingPathComponent("thumbs", isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("OneSpace/thumbs", isDirectory: true)
        }
        directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 200
    }

    /// Returns a cached thumbnail, creating one from `fileURL` when needed.
    /// Safe to call off the main thread: thumbnails are built with ImageIO, not `NSImage.lockFocus`.
    func thumbnail(for fileURL: URL, maxPixelSize: CGFloat = 320) -> NSImage? {
        let key = cacheKey(for: fileURL, maxPixelSize: maxPixelSize)
        let nsKey = key as NSString

        lock.lock()
        if let cached = memory.object(forKey: nsKey) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let diskURL = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        if let stored = NSImage(contentsOf: diskURL) {
            lock.lock()
            memory.setObject(stored, forKey: nsKey)
            lock.unlock()
            return stored
        }

        guard let created = Self.makeThumbnail(url: fileURL, maxPixelSize: maxPixelSize) else {
            return nil
        }
        store(created, to: diskURL)
        lock.lock()
        memory.setObject(created, forKey: nsKey)
        lock.unlock()
        return created
    }

    private func cacheKey(for fileURL: URL, maxPixelSize: CGFloat) -> String {
        let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let raw = "\(fileURL.standardizedFileURL.resolvingSymlinksInPath().path)|\(mtime)|\(Int(maxPixelSize.rounded()))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private func store(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
