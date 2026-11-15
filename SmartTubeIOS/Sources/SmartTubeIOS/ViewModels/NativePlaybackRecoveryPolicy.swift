#if os(macOS)
import Foundation

/// One budget for a selected video's native startup and subsequent transport recovery.
/// A rejected signed URL is never retried during the same recovery sequence.
enum NativePlaybackRecoveryPolicy {
    static let sequenceTimeout: Duration = .seconds(90)
    static let resolutionPasses = 2
    static let interruptionRecoveries = 2
    static let stalledPlaybackInterval: TimeInterval = 20
    static let minimumAdvancement: TimeInterval = 0.1
    static let monitorInterval: Duration = .seconds(1)

    enum FailureKind: String {
        case rejected, expired, network, unsupported, timeout, configuration, unavailable, unknown
    }

    static func shouldRefresh(after error: Error) -> Bool {
        switch classify(error) {
        case .configuration, .unavailable: return false
        default: return true
        }
    }

    /// URL is kept only in memory for deduplication; never include it in diagnostics.
    static func failedMediaURL(_ error: Error) -> String? {
        var current = error as NSError
        for _ in 0..<8 {
            if let url = current.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { return url }
            if let url = current.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url.absoluteString }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return nil
    }

    static func classify(_ error: Error, now: Date = Date(), url: String? = nil) -> FailureKind {
        if let url, let components = URLComponents(string: url),
            let raw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
            let expiration = Double(raw), expiration <= now.timeIntervalSince1970
        { return .expired }
        if let failure = error as? YTDLPProcessRunner.ExtractionFailure {
            switch failure {
            case .signIn, .unavailable, .upcoming: return .unavailable
            case .challenge: return .configuration
            case .delivery: return .rejected
            case .network: return .network
            }
        }
        if let failure = error as? YTDLPStreamResolver.Failure {
            if failure == .timeout { return .timeout }
            if failure == .unsupported { return .unsupported }
            if [.missingExecutable, .launch, .invalidOutput, .ffmpeg].contains(failure) { return .configuration }
            if failure == .processing { return .unavailable }
        }
        var current = error as NSError
        // AVFoundation wraps HTTP errors in several nested NSError objects.
        for _ in 0..<8 {
            if current.code == 403 || current.code == 401 { return .rejected }
            for key in ["HTTPStatusCode", "statusCode", "AVErrorHTTPStatusCodeKey"] {
                if let status = current.userInfo[key] as? Int, status == 403 || status == 401 { return .rejected }
            }
            if current.domain == NSURLErrorDomain {
                if current.code == NSURLErrorTimedOut { return .timeout }
                if [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                    NSURLErrorDNSLookupFailed].contains(current.code) { return .network }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return .unknown
    }
}
#endif
