#if os(macOS)
import AppKit
import Foundation
import ImageIO
import SmartTubeIOSCore
import SwiftUI

/// Extractor storyboard sheets are metadata, never decoded video segments.
struct StoryboardPreview: Sendable {
    struct Sheet: Sendable {
        let url: URL
        let start: Double
        let duration: Double
    }
    let rows: Int
    let columns: Int
    let sheets: [Sheet]

    func frame(at time: Double) -> (sheet: Sheet, index: Int)? {
        guard rows > 0, columns > 0,
              let sheet = sheets.last(where: { $0.start <= time }) else { return nil }
        let fraction = min(max((time - sheet.start) / sheet.duration, 0), 0.999999)
        return (sheet, min(rows * columns - 1, Int(fraction * Double(rows * columns))))
    }
}

/// Small, shared decoded-image cache. Requests belong to visible hover views and
/// SwiftUI cancels obsolete requests when their sheet or view identity changes.
@MainActor
private enum StoryboardImageCache {
    static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 12
        return cache
    }()
    static func image(for url: URL) async throws -> NSImage {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cg.width <= 8192, cg.height <= 8192,
              cg.bytesPerRow * cg.height <= 12 * 1024 * 1024 else {
            throw URLError(.cannotDecodeContentData)
        }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }
}

struct StoryboardFrameView: View {
    let storyboard: StoryboardPreview
    let time: Double
    @State private var sheetImage: NSImage?
    private var frame: (sheet: StoryboardPreview.Sheet, index: Int)? { storyboard.frame(at: time) }

    var body: some View {
        Group {
            if let sheetImage, let frame,
               let cg = sheetImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let width = cg.width / storyboard.columns
                let height = cg.height / storyboard.rows
                let rect = CGRect(x: (frame.index % storyboard.columns) * width,
                                  y: (frame.index / storyboard.columns) * height,
                                  width: width, height: height)
                if let crop = cg.cropping(to: rect) {
                    Image(decorative: crop, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            } else {
                Rectangle().fill(.black.opacity(0.7))
            }
        }
        .frame(width: 160, height: 90)
        .clipped()
        .task(id: frame?.sheet.url) {
            sheetImage = nil
            guard let url = frame?.sheet.url else { return }
            do {
                let image = try await StoryboardImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                sheetImage = image
            } catch { /* Timestamp remains available when a sheet is inaccessible. */ }
        }
    }
}

struct MacTimelineProgressView: View {
    let vm: PlaybackViewModel
    @State private var hoverTime: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 40)
            let time = vm.isScrubbing ? vm.scrubTime : vm.currentTime
            let fraction = vm.duration > 0 ? min(max(time / vm.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(.red).frame(width: width * fraction, height: 4)
                ForEach(vm.sponsorSegments) { segment in
                    let start = width * min(max(segment.start / max(vm.duration, 1), 0), 1)
                    let end = width * min(max(segment.end / max(vm.duration, 1), 0), 1)
                    Rectangle().fill(segment.category.color.opacity(0.8))
                        .frame(width: max(2, end - start), height: 4).offset(x: start)
                }
                ForEach(vm.chapters) { chapter in
                    Rectangle().fill(.white.opacity(0.85)).frame(width: 2, height: 10)
                        .offset(x: width * min(max(chapter.startTime / max(vm.duration, 1), 0), 1))
                }
                Circle().fill(.white).frame(width: 12, height: 12).offset(x: max(0, width * fraction - 6))
            }
            .frame(width: width, height: 28)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverTime = min(max(location.x / width, 0), 1) * vm.duration
                case .ended: hoverTime = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard vm.duration > 0 else { return }
                    if !vm.isScrubbing { vm.beginScrubbing() }
                    vm.updateScrub(to: min(max(value.location.x / width, 0), 1) * vm.duration)
                }
                .onEnded { _ in vm.commitScrub() })
            .overlay(alignment: .bottomLeading) {
                if let previewTime = vm.isScrubbing ? vm.scrubTime : hoverTime, vm.duration > 0 {
                    VStack(spacing: 4) {
                        if let storyboard = vm.ytdlpStream?.storyboard {
                            StoryboardFrameView(storyboard: storyboard, time: previewTime)
                        } else if let url = vm.currentVideo?.thumbnailURL {
                            // Honest fallback: video's static thumbnail, never a fabricated frame.
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                                placeholder: { Color.black.opacity(0.7) }
                                .frame(width: 160, height: 90)
                        }
                        Text(formatDuration(previewTime)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    }
                    .padding(5).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 7))
                    .frame(width: 170)
                    .offset(x: min(max(width * previewTime / vm.duration - 85, 0), max(0, width - 170)), y: -32)
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 40)
        .accessibilityIdentifier("player.progressBar")
        .accessibilityLabel("Playback position")
        .accessibilityValue(formatDuration(vm.currentTime))
        .accessibilityAdjustableAction { direction in
            vm.seekRelative(seconds: direction == .increment ? 10 : -10)
        }
    }
}
#endif
