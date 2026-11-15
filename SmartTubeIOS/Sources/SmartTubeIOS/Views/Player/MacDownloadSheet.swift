#if os(macOS)
import SwiftUI
import AppKit
import SmartTubeIOSCore

struct MacDownloadSheet: View {
    let video: Video
    let heights: [Int]
    @Bindable var service: VideoDownloadService
    @Environment(\.dismiss) private var dismiss
    @State private var height = 0
    @State private var audioOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download").font(.title2)
            Text(video.title).lineLimit(2)
            Picker("Media", selection: $audioOnly) {
                Text("Video with audio").tag(false)
                Text("Audio only").tag(true)
            }.pickerStyle(.segmented).disabled(service.state.isActive)
            if !audioOnly {
                Picker("Quality", selection: $height) {
                    Text("Best available").tag(0)
                    ForEach(heights, id: \.self) { Text("\($0)p").tag($0) }
                }.disabled(service.state.isActive)
                if YTDLPDownloadRequest.ffmpeg == nil {
                    Text("FFmpeg is unavailable. Combined video downloads are limited to 360p.").font(.caption)
                }
            }
            HStack {
                Text(service.destination.path).lineLimit(2).font(.caption)
                Spacer()
                Button("Choose Folder…") { Task { await service.chooseDestination() } }
                    .disabled(service.state.isActive)
            }
            switch service.state {
            case .idle: EmptyView()
            case .fetching: ProgressView("Preparing download…")
            case .downloading(let progress):
                ProgressView(value: progress) { Text("Downloading current stream: \(Int(progress * 100))%") }
            case .saving: ProgressView("Merging video and audio…")
            case .done:
                Text("Download complete").foregroundStyle(.green)
                if let url = service.completedURL {
                    Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            case .failed(let reason): Text(reason).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if service.state.isActive {
                    Button("Cancel Download") { service.cancel() }
                } else {
                    Button("Download") {
                        service.download(video: video, height: height == 0 ? nil : height, audioOnly: audioOnly)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24).frame(width: 470)
    }
}
#endif
