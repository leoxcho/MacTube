#if os(macOS)
import CryptoKit
import Foundation
import Observation
import os

/// Immutable, checksum-verified installations. Only an atomic manifest switches
/// the backend; the signed application and bundled fallback are never modified.
actor YTDLPInstallation {
    static let shared = YTDLPInstallation()
    // Isolate update requests from user cookies and stored network credentials.
    private let updateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    struct Version: Codable, Sendable {
        let tag: String
        let directory: String
        let sha256: String
    }
    private struct Manifest: Codable {
        var active: Version?
        var previous: Version?
    }
    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browser_download_url: String
            let digest: String?
        }
        let tag_name: String
        let assets: [Asset]
        let prerelease: Bool
        let draft: Bool
    }
    enum Failure: LocalizedError {
        case invalidRelease, invalidChecksum, invalidBinary, invalidVersion, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidRelease: "The official stable release did not provide a supported macOS download."
            case .invalidChecksum: "The download did not match its official SHA-256 checksum. The current backend was retained."
            case .invalidBinary: "The downloaded backend does not contain a usable Apple Silicon executable."
            case .invalidVersion: "The downloaded backend did not report the expected release version."
            case .unavailable: "The official update service is unavailable. The current backend was retained."
            }
        }
    }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTube/yt-dlp", isDirectory: true)
    }
    private static var manifestURL: URL { directory.appendingPathComponent("installation.json") }
    private static var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    private static let verifiedCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Hash once per immutable file identity, keeping resolver launches cheap.
    nonisolated static var preferredExecutable: String? {
        guard let manifest = readManifest(), let version = manifest.active,
              let url = verifiedURL(version) else { return nil }
        return url.path
    }
    nonisolated private static func readManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
    nonisolated private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count < 160 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        } && value != "." && value != ".."
    }
    nonisolated private static func verifiedURL(_ version: Version) -> URL? {
        guard validComponent(version.directory), version.sha256.count == 64 else { return nil }
        let url = directory.appendingPathComponent(version.directory).appendingPathComponent("yt-dlp_macos")
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let key = "\(url.path):\(attributes[.size] ?? 0):\(attributes[.modificationDate] ?? Date.distantPast)"
        if verifiedCache.withLock({ $0[key] }) == version.sha256 { return url }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), hash(data) == version.sha256 else { return nil }
        verifiedCache.withLock { $0 = [key: version.sha256] }
        return url
    }
    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func executablePath() -> String { Self.preferredExecutable ?? YTDLPProcessRunner.bundledExecutable }
    func canRestore() -> Bool { Self.readManifest()?.active != nil }
    func pending() -> Version? {
        guard let data = try? Data(contentsOf: Self.pendingURL),
              let version = try? JSONDecoder().decode(Version.self, from: data),
              Self.verifiedURL(version) != nil else { return nil }
        return version
    }
    func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.timeoutInterval = 25
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacTube-Backend-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await updateSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.unavailable }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.prerelease, !release.draft, Self.validComponent(release.tag_name) else { throw Failure.invalidRelease }
        return release
    }
    private func download(_ asset: Release.Asset) async throws -> Data {
        guard let url = URL(string: asset.browser_download_url), url.scheme == "https",
              url.host == "github.com", url.path.hasPrefix("/yt-dlp/yt-dlp/releases/download/") else { throw Failure.invalidRelease }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await updateSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { throw Failure.unavailable }
        return data
    }
    /// Inspect Mach-O headers directly, without requiring Xcode/CLI tools.
    nonisolated private static func containsARM64(_ data: Data) -> Bool {
        func word(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let bytes = Array(data[offset..<(offset + 4)])
            let ordered = little ? Array(bytes.reversed()) : bytes
            return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0) else { return false }
        if magic == 0xcffaedfe { return word(4, little: true) == 0x0100000c }
        if magic == 0xfeedfacf { return word(4) == 0x0100000c }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        guard [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic),
              let count = word(4, little: little), count > 0, count <= 32 else { return false }
        let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
        return (0..<Int(count)).contains { word(8 + $0 * stride, little: little) == 0x0100000c }
    }
    func stage(_ release: Release) async throws -> Version {
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" }) else { throw Failure.invalidRelease }
        let expected: String
        if let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71 {
            expected = String(digest.dropFirst(7)).lowercased()
        } else {
            guard let sums = release.assets.first(where: { $0.name == "SHA2-256SUMS" }) else { throw Failure.invalidChecksum }
            let bytes = try await download(sums)
            let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
            guard let line = lines.first(where: {
                $0.split(whereSeparator: \.isWhitespace).last.map { $0 == "yt-dlp_macos" || $0 == "*yt-dlp_macos" } == true
            }), let checksum = line.split(whereSeparator: \.isWhitespace).first, checksum.count == 64 else { throw Failure.invalidChecksum }
            expected = checksum.lowercased()
        }
        let bytes = try await download(asset)
        guard Self.hash(bytes) == expected else { throw Failure.invalidChecksum }
        try Task.checkCancellation()
        let version = Version(tag: release.tag_name, directory: "\(release.tag_name)-\(expected.prefix(16))", sha256: expected)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = Self.directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("yt-dlp_macos")
        try bytes.write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = YTDLPProcessRunner()
        guard Self.containsARM64(bytes) else { throw Failure.invalidBinary }
        let output = try await runner.runExecutable(at: executable, arguments: ["--ignore-config", "--version"], timeout: .seconds(20))
        guard String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == release.tag_name else { throw Failure.invalidVersion }
        let destination = Self.directory.appendingPathComponent(version.directory)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard Self.verifiedURL(version) != nil else { throw Failure.invalidChecksum }
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try JSONEncoder().encode(version).write(to: Self.pendingURL, options: .atomic)
        return version
    }
    /// Keep the exact bundled executable even after a later app replacement.
    private func preserveBundledFallback() throws -> Version {
        let source = URL(fileURLWithPath: YTDLPProcessRunner.bundledExecutable)
        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
        let checksum = Self.hash(bytes)
        let version = Version(tag: "bundled", directory: "bundled-\(checksum.prefix(16))", sha256: checksum)
        let folder = Self.directory.appendingPathComponent(version.directory)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let executable = folder.appendingPathComponent("yt-dlp_macos")
            try bytes.write(to: executable, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        guard Self.verifiedURL(version) != nil else { throw Failure.invalidChecksum }
        return version
    }
    func activate(_ version: Version) throws {
        guard Self.verifiedURL(version) != nil else { throw Failure.invalidChecksum }
        let current: Version
        if let active = Self.readManifest()?.active, Self.verifiedURL(active) != nil { current = active }
        else { current = try preserveBundledFallback() }
        if current.directory != version.directory {
            try JSONEncoder().encode(Manifest(active: version, previous: current)).write(to: Self.manifestURL, options: .atomic)
        }
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }
    func restore() throws {
        guard let manifest = Self.readManifest(), manifest.active != nil else { return }
        if let previous = manifest.previous, Self.verifiedURL(previous) == nil { throw Failure.invalidChecksum }
        try JSONEncoder().encode(Manifest(active: manifest.previous, previous: manifest.active)).write(to: Self.manifestURL, options: .atomic)
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }
}

@MainActor @Observable
final class MacYTDLPUpdateService {
    static let shared = MacYTDLPUpdateService()
    var automaticUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticUpdates, forKey: "mac.ytdlp.automaticUpdates") }
    }
    private(set) var installedVersion = "Checking…"
    private(set) var latestVersion: String?
    private(set) var lastChecked: Date?
    private(set) var status = "Bundled backend available"
    private(set) var isBusy = false
    private(set) var canRestore = false
    var message: String?
    private var release: YTDLPInstallation.Release?
    private let installation = YTDLPInstallation.shared
    private init() {
        let defaults = UserDefaults.standard
        automaticUpdates = defaults.object(forKey: "mac.ytdlp.automaticUpdates") as? Bool ?? true
        lastChecked = defaults.object(forKey: "mac.ytdlp.lastChecked") as? Date
        latestVersion = defaults.string(forKey: "mac.ytdlp.latestVersion")
    }
    private var canActivate: Bool {
        MacPlaybackSession.shared.activeModel?.isPlaying != true && !VideoDownloadService.shared.state.isActive && YTDLPProcessRunner.activeRequests == 0
    }
    func refreshInstalledVersion() async {
        let path = await installation.executablePath()
        do {
            let output = try await YTDLPProcessRunner().runExecutable(at: URL(fileURLWithPath: path), arguments: ["--ignore-config", "--version"], timeout: .seconds(15))
            installedVersion = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { installedVersion = "Unavailable" }
        canRestore = await installation.canRestore()
    }
    func checkForUpdates() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        status = "Checking…"
        recordCheckAttempt()
        await refreshInstalledVersion()
        do {
            let latest = try await installation.latestRelease()
            release = latest
            recordLatest(latest.tag_name)
            status = latest.tag_name == installedVersion ? "Up to date" : "Stable update available"
        } catch { status = "Update check failed"; message = error.localizedDescription }
    }
    func updateNow() async { await performUpdate(knownRelease: nil, manual: true) }
    private func recordCheckAttempt() {
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: "mac.ytdlp.lastChecked")
    }
    private func recordLatest(_ tag: String) {
        latestVersion = tag
        UserDefaults.standard.set(tag, forKey: "mac.ytdlp.latestVersion")
    }
    private func performUpdate(knownRelease: YTDLPInstallation.Release?, manual: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            let latest: YTDLPInstallation.Release
            if let knownRelease { latest = knownRelease }
            else {
                status = "Checking…"; recordCheckAttempt()
                latest = try await installation.latestRelease(); release = latest
            }
            recordLatest(latest.tag_name)
            if latest.tag_name == installedVersion { status = "Up to date"; return }
            status = "Downloading and verifying official backend…"
            let version = try await installation.stage(latest)
            UserDefaults.standard.set(manual, forKey: "mac.ytdlp.manualPending")
            if canActivate {
                status = "Updating…"
                try await installation.activate(version)
                UserDefaults.standard.removeObject(forKey: "mac.ytdlp.manualPending")
                await refreshInstalledVersion()
                status = "Backend updated"
            } else {
                status = "Verified update staged; activation waits for idle playback and downloads"
            }
        } catch { status = "Update failed; current backend retained"; message = error.localizedDescription }
    }
    func restorePreviousVersion() async {
        guard !isBusy else { return }
        guard canActivate else { message = "Pause playback and finish downloads before restoring the backend."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await installation.restore()
            await refreshInstalledVersion()
            status = "Previous backend restored"
            message = nil
        } catch { status = "Restore failed; current backend retained"; message = error.localizedDescription }
    }
    /// Invoked by the single low-frequency application scheduler.
    func automaticTick() async {
        guard !isBusy else { return }
        isBusy = true
        let pending = await installation.pending()
        isBusy = false
        if let pending {
            guard automaticUpdates || UserDefaults.standard.bool(forKey: "mac.ytdlp.manualPending") else { return }
            if canActivate {
                isBusy = true
                defer { isBusy = false }
                do {
                    status = "Updating…"
                    try await installation.activate(pending)
                    UserDefaults.standard.removeObject(forKey: "mac.ytdlp.manualPending")
                    await refreshInstalledVersion()
                    status = "Staged backend activated"
                } catch { status = "Activation failed; current backend retained"; message = error.localizedDescription }
            }
            return
        }
        guard automaticUpdates else { return }
        guard lastChecked.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        await refreshInstalledVersion()
        release = nil
        await checkForUpdates()
        if let release, release.tag_name != installedVersion { await performUpdate(knownRelease: release, manual: false) }
    }
}
#endif
