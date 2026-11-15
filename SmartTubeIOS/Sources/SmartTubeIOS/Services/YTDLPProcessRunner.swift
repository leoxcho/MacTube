#if os(macOS)
import Foundation
import Darwin
import os

/// File-backed output avoids pipe deadlocks. Only structured stdout leaves this actor.
actor YTDLPProcessRunner {
    /// Prefer MacTube's versioned official backend; keep the system path for package/CLI hosts.
    private static let requests = OSAllocatedUnfairLock(initialState: 0)
    static var activeRequests: Int { requests.withLock { $0 } }
    static var executable: String { YTDLPInstallation.preferredExecutable ?? bundledExecutable }
    static var bundledExecutable: String {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("MacTubeRuntime/yt-dlp_macos"),
            FileManager.default.isExecutableFile(atPath: resource.path) {
            return resource.path
        }
        return "/usr/local/bin/yt-dlp"
    }
    enum ExtractionFailure: String, LocalizedError {
        case signIn = "YouTube requires sign-in or account verification for this video."
        case unavailable = "YouTube reports this video is unavailable, private, removed, or region-restricted."
        case upcoming = "This premiere or broadcast has not started yet."
        case challenge = "YouTube JavaScript challenge resolution failed. Check the bundled yt-dlp and Deno runtime."
        case delivery = "YouTube rejected media delivery (HTTP 403). Fresh stream resolution or a compatible alternative is required."
        case network = "YouTube could not be reached. Check the network connection and try again."
        var errorDescription: String? { rawValue }
    }
    static func extractionFailure(stderr: String) -> Error {
        let message = stderr.lowercased()
        if message.contains("has not yet begun") || message.contains("will begin in") || message.contains("premieres in") { return ExtractionFailure.upcoming }
        if message.contains("sign in") || message.contains("login required") || message.contains("age-restricted") || message.contains("members-only") { return ExtractionFailure.signIn }
        if message.contains("private video") || message.contains("video unavailable") || message.contains("not available in your country") || message.contains("removed by") { return ExtractionFailure.unavailable }
        if message.contains("challenge solving failed") || message.contains("no supported javascript runtime") || message.contains("signature extraction failed") { return ExtractionFailure.challenge }
        if message.contains("http error 403") { return ExtractionFailure.delivery }
        if message.contains("timed out") || message.contains("unable to download") || message.contains("name or service not known") || message.contains("nodename nor servname") { return ExtractionFailure.network }
        return YTDLPStreamResolver.Failure.extraction
    }
    static var javascriptRuntime: String {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("MacTubeRuntime/deno"),
            FileManager.default.isExecutableFile(atPath: resource.path) { return resource.path }
        return "/usr/local/bin/deno"
    }
    static var commonArguments: [String] { [
        "--ignore-config", "--no-playlist", "--no-warnings", "--js-runtimes", "deno:\(javascriptRuntime)",
        "--socket-timeout", "15", "--retries", "1",
    ] }
    static func watchURL(_ videoID: String) throws -> String {
        guard !videoID.isEmpty,
            videoID.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else { throw YTDLPStreamResolver.Failure.invalidOutput }
        return "https://www.youtube.com/watch?v=\(videoID)"
    }
    func run(
        arguments: [String], timeout: Duration,
        progress: (@Sendable (Data) async -> Void)? = nil
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: Self.javascriptRuntime) else {
            throw YTDLPStreamResolver.Failure.missingExecutable
        }
        return try await execute(at: URL(fileURLWithPath: Self.executable), arguments: Self.commonArguments + arguments,
                                 timeout: timeout, progress: progress)
    }

    /// Reuses the resolver's bounded, cancellable process lifecycle for version
    /// and native compatibility probes, without extractor/Deno arguments.
    func runExecutable(at url: URL, arguments: [String], timeout: Duration) async throws -> Data {
        try await execute(at: url, arguments: arguments, timeout: timeout, progress: nil)
    }
    private func execute(at url: URL, arguments: [String], timeout: Duration,
                         progress: (@Sendable (Data) async -> Void)?) async throws -> Data {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw YTDLPStreamResolver.Failure.missingExecutable }
        Self.requests.withLock { $0 += 1 }
        defer { Self.requests.withLock { $0 -= 1 } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let writer = try FileHandle(forWritingTo: output)
        let reader = try FileHandle(forReadingFrom: output)
        defer {
            try? writer.close()
            try? reader.close()
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = writer
        let diagnostics = directory.appendingPathComponent("diagnostics")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let diagnosticWriter = try FileHandle(forWritingTo: diagnostics)
        defer { try? diagnosticWriter.close() }
        process.standardError = diagnosticWriter
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw YTDLPStreamResolver.Failure.launch }
        defer {
            if process.isRunning {
                let pid = process.processIdentifier
                kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
        }
        let deadline = ContinuousClock.now + timeout
        var data = Data()
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw YTDLPStreamResolver.Failure.timeout }
            let chunk = reader.readDataToEndOfFile()
            data.append(chunk)
            if let progress, !chunk.isEmpty { await progress(chunk) }
            if progress != nil, data.count > 65_536 { data.removeFirst(data.count - 65_536) }
            guard data.count < 32 * 1024 * 1024 else { throw YTDLPStreamResolver.Failure.invalidOutput }
            try await Task.sleep(for: .milliseconds(200))
        }
        let chunk = reader.readDataToEndOfFile()
        data.append(chunk)
        if let progress, !chunk.isEmpty { await progress(chunk) }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let diagnosticReader = try FileHandle(forReadingFrom: diagnostics)
            defer { try? diagnosticReader.close() }
            let errorData = try diagnosticReader.read(upToCount: 65_536) ?? Data()
            throw Self.extractionFailure(stderr: String(decoding: errorData, as: UTF8.self))
        }
        return data
    }
}
#endif
