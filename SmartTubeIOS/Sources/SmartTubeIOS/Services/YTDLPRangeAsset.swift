#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

/// Per-asset byte-range delivery through URLSession; no server or transcoding.
@MainActor
final class YTDLPRangeLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let url: URL
    let headers: [String: String]
    let contentType: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(url: URL, headers: [String: String], audioOnly: Bool) {
        self.url = url
        self.headers = headers
        self.contentType = audioOnly ? UTType.mpeg4Audio.identifier : UTType.mpeg4Movie.identifier
    }
    func resourceLoader(
        _ loader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(request)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { tasks.removeValue(forKey: key) }
            do {
                let dataRequest = request.dataRequest
                let start = max(dataRequest?.requestedOffset ?? 0, dataRequest?.currentOffset ?? 0)
                let all = dataRequest?.requestsAllDataToEndOfResource == true
                let (sum, overflow) = (dataRequest?.requestedOffset ?? 0).addingReportingOverflow(Int64(dataRequest?.requestedLength ?? 2))
                let requestedEnd = overflow ? Int64.max : sum
                let length = max(Int64(1), requestedEnd - start)
                var fetch = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                fetch.allHTTPHeaderFields = headers
                fetch.httpShouldHandleCookies = false
                fetch.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                fetch.setValue(
                    all ? "bytes=\(start)-" : "bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range"
                )
                let (bytes, response) = try await URLSession.shared.bytes(for: fetch)
                guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                    Logger(subsystem: "com.mactube.app", category: "NativeRangeDelivery")
                        .error("Media request rejected status=\((response as? HTTPURLResponse)?.statusCode ?? 0) start=\(start) length=\(length) toEnd=\(all)")
                    throw NSError(domain: "MacTube.MediaHTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let range = try Self.responseRange(http, start: start)
                let total = range?.total ?? response.expectedContentLength
                if let info = request.contentInformationRequest {
                    guard total > 0 else { throw Self.transportError("Missing media content length") }
                    info.contentType = contentType
                    info.contentLength = total
                    info.isByteRangeAccessSupported = http.statusCode == 206
                }
                if let dataRequest {
                    var buffer = Data()
                    var received: Int64 = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        received += 1
                        if buffer.count >= 65_536 {
                            dataRequest.respond(with: buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                        if !all, received >= length { break }
                    }
                    try Task.checkCancellation()
                    let expected = all ? (range.map { $0.end - start + 1 } ?? total - start)
                        : min(length, range.map { $0.end - start + 1 } ?? total - start)
                    guard received >= expected else { throw Self.transportError("Truncated media response") }
                    if !buffer.isEmpty { dataRequest.respond(with: buffer) }
                }
                try Task.checkCancellation()
                request.finishLoading()
            } catch {
                if !Task.isCancelled {
                    let failure = error as NSError
                    var info = failure.userInfo
                    info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
                    request.finishLoading(with: NSError(domain: failure.domain, code: failure.code, userInfo: info))
                }
            }
        }
        return true
    }
    private static func transportError(_ description: String) -> NSError {
        NSError(domain: "MacTube.MediaHTTP", code: -2, userInfo: [NSLocalizedDescriptionKey: description])
    }
    /// A 206 is useful only when its actual byte interval matches the requested offset.
    static func responseRange(_ http: HTTPURLResponse, start: Int64) throws -> (end: Int64, total: Int64)? {
        guard http.statusCode == 206 else {
            guard start == 0 else { throw transportError("Server ignored the media Range request") }
            return nil
        }
        guard let raw = http.value(forHTTPHeaderField: "Content-Range"), raw.hasPrefix("bytes ") else {
            throw transportError("Missing media Content-Range")
        }
        let parts = raw.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else {
            throw transportError("Invalid media content length")
        }
        let interval = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard interval.count == 2, let first = Int64(interval[0]), let end = Int64(interval[1]),
            first == start, end >= first, end < total,
            http.expectedContentLength < 0 || http.expectedContentLength == end - first + 1
        else { throw transportError("Mismatched media Content-Range") }
        return (end, total)
    }
    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
}

final class YTDLPRangeAsset: AVURLAsset, @unchecked Sendable {
    private let rangeLoader: YTDLPRangeLoader
    @MainActor init(mediaURL: URL, headers: [String: String], audioOnly: Bool = false) {
        rangeLoader = YTDLPRangeLoader(url: mediaURL, headers: headers, audioOnly: audioOnly)
        let virtual = URL(string: "mactubemedia://stream/\(UUID().uuidString).\(audioOnly ? "m4a" : "mp4")")!
        super.init(url: virtual, options: [AVURLAssetOverrideMIMETypeKey: audioOnly ? "audio/mp4" : "video/mp4"])
        resourceLoader.setDelegate(rangeLoader, queue: .main)
    }
}
#endif
