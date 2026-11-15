#if os(macOS)
import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A lazy, on-disk video thumbnail pipeline; one generator runs at a time.
private actor MacLocalThumbnailCache {
    static let shared = MacLocalThumbnailCache()
    private var tail: Task<URL?, Never>?
    private var writes = 0
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTube/Thumbnails", isDirectory: true)
    }
    func thumbnail(for entry: MacMediaEntry) async -> URL? {
        guard !entry.isAudio, entry.isAvailable, !Task.isCancelled else { return nil }
        let key = SHA256.hash(data: Data((entry.id + entry.fingerprint).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let destination = Self.directory.appendingPathComponent(key).appendingPathExtension("jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let predecessor = tail
        let task = Task<URL?, Never> {
            _ = await predecessor?.value
            guard !Task.isCancelled else { return nil }
            // Another queued request may already have generated this exact fingerprint.
            if FileManager.default.fileExists(atPath: destination.path) { return destination }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: entry.fileURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let cancellation = MacThumbnailCancellation(generator)
            return await withTaskCancellationHandler {
                do {
                    let seconds = min(5, max(0, entry.duration * 0.1))
                    let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                    // Write atomically so a cancelled or failed request cannot publish a partial JPEG.
                    let temporary = Self.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                    CGImageDestinationAddImage(output, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
                    guard CGImageDestinationFinalize(output) else { return nil }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    return destination
                } catch { return nil }
            } onCancel: { cancellation.cancel() }
        }
        tail = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if result != nil {
            writes += 1
            if writes % 32 == 0 { trimCache() }
        }
        return result
    }
    private func trimCache() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let files = urls.filter { $0.pathExtension == "jpg" }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, file) in files.enumerated() {
            bytes += file.2
            if index >= 512 || bytes > 128 * 1024 * 1024 { try? FileManager.default.removeItem(at: file.0) }
        }
    }
}

/// AVFoundation allows pending image generation to be cancelled from another thread.
private final class MacThumbnailCancellation: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(_ generator: AVAssetImageGenerator) { self.generator = generator }
    func cancel() { generator.cancelAllCGImageGeneration() }
}

struct MacLocalMediaArtwork: View {
    let entry: MacMediaEntry
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                Image(systemName: entry.isAudio ? "music.note" : "play.rectangle")
                    .font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: entry.id + entry.fingerprint) {
            image = nil
            var url = entry.thumbnailURL?.isFileURL == true ? entry.thumbnailURL : nil
            if url == nil { url = await MacLocalThumbnailCache.shared.thumbnail(for: entry) }
            guard !Task.isCancelled, let url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return }
            // NSImage is created and assigned only on SwiftUI's main actor.
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
#endif
