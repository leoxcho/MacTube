import Foundation

/// Distinguishes consecutive requests for the same video, including cancelled requests.
struct PlaybackSessionLease {
    private(set) var token = UUID()
    private(set) var parkedAt: Date?
    static let reuseLifetime: TimeInterval = 90
    static let expiryMargin: TimeInterval = 30

    mutating func advance() { token = UUID() }
    mutating func park(at date: Date = Date()) { parkedAt = date }
    func isCurrent(_ candidate: UUID) -> Bool { token == candidate }
    func canReuse(now: Date = Date(), resolvedAt: Date?, urls: [URL], isLive: Bool) -> Bool {
        guard !isLive, let parkedAt, now.timeIntervalSince(parkedAt) >= 0,
            now.timeIntervalSince(parkedAt) < Self.reuseLifetime
        else { return false }
        if let resolvedAt, now.timeIntervalSince(resolvedAt) >= Self.reuseLifetime { return false }
        return urls.allSatisfy { url in
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "expire" })?.value
            guard let raw else { return true }
            guard let seconds = Double(raw) else { return false }
            return seconds > now.timeIntervalSince1970 + Self.expiryMargin
        }
    }
}
