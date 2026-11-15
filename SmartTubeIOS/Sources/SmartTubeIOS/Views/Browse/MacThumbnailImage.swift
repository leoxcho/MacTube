#if os(macOS)
import AppKit
import ImageIO
import SwiftUI

/// Shared decoded thumbnail cache. URL tasks belong to visible views and cancel on reuse.
@MainActor
private enum MacThumbnailCache {
    static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func image(for url: URL) async throws -> NSImage {
        if let image = images.object(forKey: url as NSURL) { return image }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { throw URLError(.cannotDecodeContentData) }
        let image = NSImage(cgImage: cgImage, size: .zero)
        images.setObject(image, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

struct MacThumbnailImage: View {
    let url: URL?
    var failed: () -> Void = {}
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Color.secondary.opacity(0.15) }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            do { image = try await MacThumbnailCache.image(for: url) }
            catch { if !Task.isCancelled { failed() } }
        }
    }
}

/// YouTube's three published stills give a small hover preview without a video decoder.
struct MacCardThumbnailPreview: View {
    let videoID: String
    @State private var frame = 1
    @State private var unavailable = false
    @State private var ready = false
    var body: some View {
        GeometryReader { geometry in
            if ready && !unavailable {
                MacThumbnailImage(url: URL(string: "https://i.ytimg.com/vi/\(videoID)/\(frame).jpg"),
                                  failed: { unavailable = true })
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: videoID) {
            frame = 1
            unavailable = false
            ready = false
            do {
                // A small dwell avoids requests as the pointer crosses cards while scrolling.
                try await Task.sleep(for: .milliseconds(450))
                ready = true

            } catch { }
        }
    }
}
#endif
