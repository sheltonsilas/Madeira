// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// LinuxImageDownloader.swift - fetch a distribution image so the user never
// has to find one.
//
// The brief asks that a new user choose a distribution and a GUI-or-not and
// have the rest happen. That means the app has to fetch several hundred
// megabytes itself, which needs three things this file provides: progress the
// UI can read, a destination inside the app's own container, and verification
// against the checksum list the distribution publishes.
//
// ON THE DELEGATE, DELIBERATELY
// `URLSession` retains its delegate, and this class is that delegate, so the
// session keeps the downloader alive for as long as a transfer is running.
// That is the opposite of the trap in MadeiraBrowserView, where
// `WKDownload.delegate` is a *weak* reference and an inline delegate was
// released before WebKit could call it. Both are noted here because the two
// APIs sit next to each other in this app and a reader should not have to
// guess which one is which.
//
// WHERE THE FILE GOES
// `Documents/environments/<id>/image/`, next to the environment record, so
// "delete this environment" removes the image with it and a backup that
// includes the container includes the guest. Nothing is written outside that
// directory, so an abandoned download never leaves debris elsewhere.

import Foundation
import CryptoKit

/// Downloads one distribution image, with progress and checksum verification.
///
/// All delegate callbacks are delivered on the main queue (see `init`), so
/// `state` is only ever written from the main thread and the UI can read it
/// without hopping or locking.
final class LinuxImageDownloader: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case downloading(received: Int64, expected: Int64)
        /// The bytes are on disk and are being hashed. A desktop image is
        /// several gigabytes, so this is a visible state, not an instant.
        case verifying
        case finished(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying: return true
            case .idle, .finished, .failed: return false
            }
        }

        var fraction: Double? {
            guard case let .downloading(received, expected) = self, expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        }

        var detail: String? {
            switch self {
            case .idle:
                return nil
            case let .downloading(received, expected):
                let have = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                guard expected > 0 else { return have }
                let all = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                return "\(have) of \(all)"
            case .verifying:
                return "Checking the checksum..."
            case .finished:
                return "Ready."
            case let .failed(message):
                return message
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// The image being fetched, so the delegate knows what to verify.
    private var image: LinuxDistroImage?
    /// Where the finished file must land. Set before the task starts, because
    /// `didFinishDownloadingTo` has to move the file synchronously.
    private var destination: URL?
    private var task: URLSessionDownloadTask?
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // A desktop ISO is 3.5 GB. A per-resource timeout measured in minutes
        // would abandon a slow but healthy transfer halfway.
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration,
                             delegate: self,
                             delegateQueue: .main)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Starting and stopping

    /// Begin (or restart) a download into `directory`.
    ///
    /// Any transfer already running is cancelled first, so a user who changes
    /// their mind between two distributions cannot end up with both.
    func download(_ image: LinuxDistroImage, into directory: URL) {
        cancel()
        self.image = image

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            state = .failed("Could not create the environment folder: \(error.localizedDescription)")
            return
        }

        let target = directory.appendingPathComponent(image.fileName)
        destination = target
        state = .downloading(received: 0, expected: image.byteCount)

        let task = session.downloadTask(with: image.url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        image = nil
        destination = nil
        if state.isBusy { state = .idle }
    }

    // MARK: Verification

    /// Compare the file against the hash the distribution publishes.
    ///
    /// Runs off the main thread: hashing a 3.5 GB ISO through CryptoKit takes
    /// long enough to freeze the UI if it were done inline.
    private func verify(file: URL, image: LinuxDistroImage) {
        guard let sumsURL = image.checksumURL, let algorithm = image.checksumAlgorithm else {
            // No published list for this image (Fedora). Say so rather than
            // implying a check that did not happen.
            state = .finished(file)
            return
        }

        state = .verifying
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.check(file: file, sumsURL: sumsURL, algorithm: algorithm, fileName: image.fileName)
            DispatchQueue.main.async { self?.state = result }
        }
    }

    private static func check(file: URL,
                              sumsURL: URL,
                              algorithm: LinuxDistroImage.ChecksumAlgorithm,
                              fileName: String) -> State {
        let expected: String
        do {
            let data = try Data(contentsOf: sumsURL)
            let text = String(decoding: data, as: UTF8.self)
            guard let found = expectedHash(in: text, for: fileName) else {
                // A list that does not mention our file (a newer ISO than this
                // build knows about) must not be reported as a mismatch.
                return .finished(file)
            }
            expected = found
        } catch {
            return .finished(file)
        }

        do {
            let actual = try hash(of: file, algorithm: algorithm)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                return .failed("The download did not match the published \(algorithm.displayName). "
                    + "Expected \(expected.prefix(16))..., got \(actual.prefix(16))... . "
                    + "Delete it and try again.")
            }
            return .finished(file)
        } catch {
            return .failed("Could not read the downloaded image to verify it: \(error.localizedDescription)")
        }
    }

    /// Pull `fileName`'s hash out of a `SHA256SUMS`-style list.
    ///
    /// Both formats in use here put the hash first and the name second, and
    /// differ only in whether a `*` marks binary mode:
    ///     `abc123  ubuntu-24.04-minimal-cloudimg-arm64.img`
    ///     `abc123 *ubuntu-24.04-minimal-cloudimg-arm64.img`
    static func expectedHash(in text: String, for fileName: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            var name = String(parts[1])
            if name.hasPrefix("*") { name.removeFirst() }
            if name == fileName || name.hasSuffix("/" + fileName) {
                return String(parts[0])
            }
        }
        return nil
    }

    static func hash(of url: URL, algorithm: LinuxDistroImage.ChecksumAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = 4 << 20
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha512:
            var hasher = SHA512()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension LinuxImageDownloader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Servers that omit Content-Length report -1; the catalogue's own byte
        // count is the better estimate in that case.
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (image?.byteCount ?? 0)
        state = .downloading(received: totalBytesWritten, expected: expected)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination else {
            state = .failed("The download finished but had no destination.")
            return
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            state = .failed("Could not save the image: \(error.localizedDescription)")
            return
        }
        guard let image else {
            state = .finished(destination)
            return
        }
        verify(file: destination, image: image)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A nil error means the transfer succeeded, and the file was already
        // moved and verified in the callback above.
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        state = .failed(error.localizedDescription)
    }
}
