// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// LinuxEnvironmentPackager.swift - the streaming packager and unpackager that
// LinuxEnvironmentStore used to stub out.
//
// WHY IT STREAMS
// An environment is a rootfs whose disk image runs to gigabytes, and the iPad
// it sits on does not have a free copy of that in RAM. Everything here moves
// through a fixed one-megabyte window: nothing is ever read whole, nothing is
// ever held whole, and peak memory does not grow with the size of the image.
//
// THE ARCHIVE FORMAT
// A ustar tar, gzip-compressed. Deliberately the most boring format there is,
// because it has to be readable by `tar -xzf` on an ordinary Ubuntu box — a
// backup the user cannot open on a desktop is not a backup. The layout was not
// guessed: `build/ci/overnight/validate_tar_layout.py` writes the same bytes
// and checks them against Python's own `tarfile` reader, including the GNU
// base-256 size encoding that disks over 8 GiB need (this store offers up to
// 64 GiB, so plain octal would silently truncate).
//
// WHY zlib
// `libz.tbd` is already linked into this target and the project already calls
// `inflateInit2_` from Swift (SteamRuntime, DepotDownloader), so this adds no
// new dependency. windowBits 31 writes a real gzip container, and 47 makes the
// reader accept gzip, zlib or raw deflate, so rootfs tarballs made by other
// tools still open.
//
// SAFETY
// An archive is untrusted input. Every path is normalised and refused if it
// escapes the destination (the classic tar-slip), and nothing is written
// outside the directory the caller named.

import Foundation
import zlib

/// What can go wrong while packing or unpacking an environment.
enum PackagerError: LocalizedError {
    /// zlib refused to start, or returned a status we do not expect.
    case compression(Int32)
    /// The stream ended in the middle of a header or a file body.
    case truncated
    /// The header checksum does not match its own bytes.
    case badChecksum(String)
    /// A member tries to name a path outside the destination directory.
    case unsafePath(String)
    /// A member name cannot be expressed in the ustar name and prefix fields.
    case tooLong(String)
    /// A file could not be created while packing or unpacking.
    case createFailed(String)
    /// A file changed size between being measured and being copied.
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .compression(let code): return "Compression failed (zlib status \(code))."
        case .truncated: return "The archive ends in the middle of an entry."
        case .badChecksum(let name): return "Archive is damaged: bad checksum on \(name)."
        case .unsafePath(let name): return "Refused an entry that escapes the environment folder: \(name)"
        case .tooLong(let name): return "Path is too long to archive: \(name)"
        case .createFailed(let name): return "Could not create \(name)."
        case .changed(let name): return "\(name) changed size while it was being packed."
        }
    }
}

/// Streams an environment directory into a gzip tar, and back out again.
enum LinuxEnvironmentPackager {
    /// Written first so an import can restore the environment's settings.
    static let sidecarName = ".madeira-environment.json"

    /// The window. Bigger trades memory for fewer syscalls; a megabyte is
    /// invisible against an 8 GB image and still one syscall per megabyte.
    static let window = 1 << 20

    /// Top-level names never packed: snapshots are derived data and would
    /// double the size of every backup for something the user can retake.
    static let skippedTopLevel: Set<String> = ["snapshots"]

    private static let blockSize = 512

    // MARK: - Packing

    /// Write `source` (a directory) plus `sidecar` into a gzip tar at
    /// `destination`.
    ///
    /// On any failure the partial file is removed: a half-written archive that
    /// looks like a backup is worse than no backup, because it will be trusted
    /// until the day it is needed.
    static func pack(sidecar: Data, from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw PackagerError.createFailed(source.lastPathComponent)
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)

        do {
            try writeArchive(sidecar: sidecar, from: source, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private static func writeArchive(sidecar: Data, from source: URL, to destination: URL) throws {
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let gzip = try GzipWriter(handle: handle)
        defer { try? gzip.finish() }

        // The sidecar first: a reader of the tar sees what this environment
        // was without having to walk a rootfs.
        try gzip.write(header(name: sidecarName, size: Int64(sidecar.count),
                              typeflag: 0x30, mtime: now(), mode: 0o644))
        try gzip.write([UInt8](sidecar))
        try gzip.write(padding(sidecar.count))

        for entry in try entries(under: source) {
            if entry.isDirectory {
                try gzip.write(header(name: entry.name, prefix: entry.prefix,
                                      size: 0, typeflag: 0x35,
                                      mtime: entry.mtime, mode: entry.mode))
                continue
            }
            if let target = entry.symlinkTarget {
                let h = header(name: entry.name, prefix: entry.prefix,
                               size: 0, typeflag: 0x32,
                               mtime: entry.mtime, mode: entry.mode,
                               linkname: target)
                try gzip.write(h)
                continue
            }
            try gzip.write(header(name: entry.name, prefix: entry.prefix,
                                  size: entry.size, typeflag: 0x30,
                                  mtime: entry.mtime, mode: entry.mode))
            try streamFile(at: entry.url, into: gzip, declared: entry.size)
        }

        // Two zero blocks end a tar; without them a reader treats a short final
        // entry as corruption.
        try gzip.write([UInt8](repeating: 0, count: blockSize * 2))
    }

    /// Copy a file into the archive, refusing to lie about its length: if the
    /// file grows or shrinks mid-copy the archive would be unreadable, so the
    /// declared size and what actually lands are compared.
    private static func streamFile(at url: URL, into gzip: GzipWriter, declared: Int64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var written: Int64 = 0
        while true {
            let data = (try handle.read(upToCount: window)) ?? Data()
            if data.isEmpty { break }
            try gzip.write([UInt8](data))
            written += Int64(data.count)
        }
        if written != declared {
            throw PackagerError.changed(url.lastPathComponent)
        }
        try gzip.write(padding(Int(written)))
    }

    private static func padding(_ count: Int) -> [UInt8] {
        let rem = count % blockSize
        guard rem != 0 else { return [] }
        return [UInt8](repeating: 0, count: blockSize - rem)
    }

    // MARK: - Unpacking

    /// Extract `source` into `destination`, returning the sidecar's bytes when
    /// the archive carries one.
    ///
    /// Returns `nil` when there is no sidecar, which is the normal case for a
    /// tarball made elsewhere; the caller then keeps whatever it already knows.
    static func unpack(from source: URL, to destination: URL) throws -> Data? {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        let reader = TarReader(handle: handle, compressed: isGzip(source))
        defer { reader.close() }

        var sidecar: Data?

        while let entry = try reader.next() {
            guard let name = safeName(entry.name) else {
                throw PackagerError.unsafePath(entry.name)
            }
            let target = destination.appendingPathComponent(name)

            // The sidecar is captured, never written: it is metadata about the
            // archive, not part of the environment's filesystem.
            if name == sidecarName && entry.typeflag == 0x30 {
                var collected = Data()
                var remaining = entry.size
                while remaining > 0 {
                    let take = Int(min(remaining, Int64(window)))
                    let bytes = try reader.readSome(take)
                    if bytes.isEmpty { throw PackagerError.truncated }
                    collected.append(contentsOf: bytes)
                    remaining -= Int64(bytes.count)
                }
                sidecar = collected
                try reader.align(entry.size)
                continue
            }

            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)

            switch entry.typeflag {
            case 0x35:                                    // directory
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try reader.skipEntryBody(entry.size)
            case 0x32:                                    // symlink
                try? fm.removeItem(at: target)
                try fm.createSymbolicLink(at: target,
                                          withDestinationURL: URL(fileURLWithPath: entry.linkname))
                try reader.skipEntryBody(entry.size)
            default:                                      // regular file
                try? fm.removeItem(at: target)
                guard fm.createFile(atPath: target.path, contents: nil) else {
                    throw PackagerError.createFailed(name)
                }
                let out = try FileHandle(forWritingTo: target)
                defer { try? out.close() }
                var remaining = entry.size
                while remaining > 0 {
                    let take = Int(min(remaining, Int64(window)))
                    let bytes = try reader.readSome(take)
                    if bytes.isEmpty { throw PackagerError.truncated }
                    try out.write(contentsOf: Data(bytes))
                    remaining -= Int64(bytes.count)
                }
                try reader.align(entry.size)
            }
        }
        return sidecar
    }

    private static func isGzip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 2) else { return false }
        try? handle.close()
        guard head.count == 2 else { return false }
        return head[head.startIndex] == 0x1f && head[head.startIndex + 1] == 0x8b
    }

    /// Reject anything that would write outside the destination directory.
    ///
    /// GNU tar routinely stores members as `./usr/bin/foo`, so the leading `./`
    /// is noise and must be dropped rather than treated as a path component;
    /// rejecting it outright would refuse every member of a real rootfs
    /// tarball.
    private static func safeName(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        if s.hasPrefix("/") || s.hasPrefix("~") { return nil }
        while s.hasPrefix("./") { s.removeFirst(2) }
        guard !s.isEmpty, s != "." else { return nil }
        var out: [String] = []
        for part in s.split(separator: "/").map(String.init) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { return nil }
            out.append(part)
        }
        guard !out.isEmpty else { return nil }
        return out.joined(separator: "/")
    }

    // MARK: - Headers

    /// A ustar header. `name` is the final component (≤100 bytes) and `prefix`
    /// the directory part (≤155 bytes); together they cover the deep paths a
    /// rootfs really has.
    private static func header(name: String, prefix: String = "", size: Int64,
                               typeflag: UInt8, mtime: Int, mode: Int,
                               linkname: String? = nil) -> [UInt8] {
        let nb = Array(name.utf8)
        let pb = Array(prefix.utf8)
        precondition(nb.count <= 100 && pb.count <= 155,
                     "ustar path fields overflow: \(prefix)/\(name)")

        var h = [UInt8](repeating: 0, count: blockSize)
        for (i, b) in nb.enumerated() { h[i] = b }
        writeOctal(mode, into: &h, at: 100, width: 8)
        writeOctal(0, into: &h, at: 108, width: 8)      // uid
        writeOctal(0, into: &h, at: 116, width: 8)      // gid
        writeSize(size, into: &h, at: 124)
        writeOctal(mtime, into: &h, at: 136, width: 12)
        for i in 148..<156 { h[i] = 0x20 }              // spaces while summing
        h[156] = typeflag
        if let link = linkname {
            for (i, b) in Array(link.utf8).prefix(100).enumerated() { h[157 + i] = b }
        }
        for (i, b) in Array("ustar".utf8).enumerated() { h[257 + i] = b }
        h[262] = 0
        h[263] = 0x30
        h[264] = 0x30
        for (i, b) in Array("root".utf8).enumerated() {
            h[265 + i] = b                             // uname
            h[297 + i] = b                             // gname
        }
        for (i, b) in pb.enumerated() { h[340 + i] = b }   // prefix

        var total = 0
        for b in h { total += Int(b) }
        let chk = Array(String(format: "%06o", total).utf8)
        for (i, b) in chk.suffix(6).enumerated() { h[148 + i] = b }
        h[154] = 0
        h[155] = 0x20
        return h
    }

    private static func writeOctal(_ value: Int, into h: inout [UInt8], at offset: Int, width: Int) {
        var digits = Array(String(format: "%o", max(value, 0)).utf8)
        if digits.count > width - 1 { digits = Array(digits.suffix(width - 1)) }
        let pad = (width - 1) - digits.count
        for i in 0..<pad { h[offset + i] = 0x30 }
        for (i, b) in digits.enumerated() { h[offset + pad + i] = b }
        h[offset + width - 1] = 0
    }

    /// Octal below 8 GiB, GNU base-256 above it. The octal field tops out at
    /// 8^11 - 1, and this store offers disks up to 64 GiB, so without the
    /// second form a large image would be archived with a wrong size.
    private static func writeSize(_ value: Int64, into h: inout [UInt8], at offset: Int) {
        if value >= 0 && value < 8_589_934_592 {
            writeOctal(Int(value), into: &h, at: offset, width: 12)
            return
        }
        h[offset] = 0x80
        var v = UInt64(bitPattern: value)
        for i in stride(from: 11, through: 1, by: -1) {
            h[offset + i] = UInt8(truncatingIfNeeded: v)
            v >>= 8
        }
    }

    /// Split a relative path the way ustar does: as much of the directory part
    /// as fits in 155 bytes, the last component in the remaining 100.
    private static func splitPath(_ rel: String) -> (name: String, prefix: String)? {
        if rel.utf8.count <= 100 { return (rel, "") }
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        for cut in stride(from: parts.count - 1, through: 1, by: -1) {
            let prefix = parts[..<cut].joined(separator: "/")
            let name = parts[cut...].joined(separator: "/")
            if prefix.utf8.count <= 155 && name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        return nil
    }

    private static func entries(under root: URL) throws -> [Entry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw PackagerError.createFailed(root.lastPathComponent)
        }
        var found: [Entry] = []
        for case let url as URL in en {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            guard !rel.isEmpty else { continue }

            let values = (try? url.resourceValues(forKeys: keys)) ?? URLResourceValues()
            let isDir = values.isDirectory ?? false
            let isLink = values.isSymbolicLink ?? false

            // Never pack the snapshots folder, nor anything inside it.
            if skippedTopLevel.contains(rel) {
                if isDir { en.skipDescendants() }
                continue
            }

            guard let split = splitPath(rel) else { throw PackagerError.tooLong(rel) }
            let target = isLink ? (try? fm.destinationOfSymbolicLink(atPath: url.path)) : nil
            found.append(Entry(url: url,
                               name: split.name,
                               prefix: split.prefix,
                               isDirectory: isDir,
                               symlinkTarget: target,
                               size: isDir || isLink ? 0 : Int64(values.fileSize ?? 0),
                               mtime: Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                               mode: isDir ? 0o755 : 0o644))
        }
        return found.sorted { ($0.prefix + "/" + $0.name) < ($1.prefix + "/" + $1.name) }
    }

    private static func now() -> Int { Int(Date().timeIntervalSince1970) }

    private struct Entry {
        let url: URL
        let name: String
        let prefix: String
        let isDirectory: Bool
        let symlinkTarget: String?
        let size: Int64
        let mtime: Int
        let mode: Int
    }
}

// MARK: - gzip writer

/// Pushes bytes through deflate and into a file, one window at a time.
private final class GzipWriter {
    private var stream = z_stream()
    private let handle: FileHandle
    private let capacity = LinuxEnvironmentPackager.window
    private var closed = false

    init(handle: FileHandle) throws {
        self.handle = handle
        // 31 = 15 (deflate window) + 16 (emit a gzip container; zlib writes the
        // header, the CRC32 and the ISIZE trailer itself).
        let rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8,
                               Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                               Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw PackagerError.compression(rc) }
    }

    func write(_ bytes: [UInt8]) throws {
        guard !closed, !bytes.isEmpty else { return }
        try bytes.withUnsafeBufferPointer { ptr in
            stream.next_in = UnsafeMutablePointer(mutating: ptr.baseAddress)
            stream.avail_in = UInt32(ptr.count)
            try pump(finishing: false)
        }
    }

    /// Writes the gzip trailer. Safe to call twice: the caller's `defer` runs
    /// it even when the body threw.
    func finish() throws {
        guard !closed else { return }
        closed = true
        stream.next_in = nil
        stream.avail_in = 0
        try pump(finishing: true)
        deflateEnd(&stream)
    }

    private func pump(finishing: Bool) throws {
        var out = [UInt8](repeating: 0, count: capacity)
        while true {
            let before = stream.avail_in
            let rc: Int32 = out.withUnsafeMutableBytes { buf -> Int32 in
                stream.next_out = buf.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = UInt32(capacity)
                return deflate(&stream, finishing ? Z_FINISH : Z_NO_FLUSH)
            }
            let produced = capacity - Int(stream.avail_out)
            if produced > 0 { try handle.write(contentsOf: Data(out[0 ..< produced])) }

            if rc == Z_STREAM_END { return }
            if rc != Z_OK && rc != Z_BUF_ERROR { throw PackagerError.compression(rc) }
            if finishing { continue }
            if stream.avail_in == 0 { return }
            // No input consumed and nothing produced: deflate cannot make
            // progress, so stop rather than spin.
            if produced == 0 && stream.avail_in == before {
                throw PackagerError.compression(rc)
            }
        }
    }
}

// MARK: - tar reader

/// Pulls 512-byte headers and file bodies out of a possibly-gzipped file.
private final class TarReader {
    struct Header {
        let name: String
        let linkname: String
        let size: Int64
        let typeflag: UInt8
    }

    private let handle: FileHandle
    private let inflater: Inflater?
    private let compressed: Bool
    private var finished = false

    init(handle: FileHandle, compressed: Bool) {
        self.handle = handle
        self.compressed = compressed
        // windowBits 47 = 15 + 32: accept a gzip container or a zlib one,
        // whichever the producer used, without the caller sniffing it out.
        self.inflater = compressed ? Inflater(handle: handle) : nil
    }

    func close() {
        inflater?.close()
    }

    /// The next real header, or nil once the archive is over.
    ///
    /// Metadata entries are consumed here rather than surfaced: GNU's `L`
    /// carries a name longer than 100 bytes, pax's `x` carries a `path=` for
    /// the entry that follows, and both must be folded into the next header or
    /// a deep rootfs path arrives truncated.
    func next() throws -> Header? {
        guard !finished else { return nil }
        var longName: String?
        var paxPath: String?

        while true {
            guard let block = try readBlock() else { return nil }
            guard !block.allSatisfy({ $0 == 0 }) else {
                finished = true
                return nil
            }
            guard Self.checksumValid(block) else {
                throw PackagerError.badChecksum(Self.cString(block, 0, 100))
            }

            let typeflag = block[156]
            let size = Self.parseSize(Array(block[124 ..< 136]))

            switch typeflag {
            case 0x4C:                                   // 'L' GNU long name
                longName = String(decoding: try consumeBody(size), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                continue
            case 0x58:                                   // 'x' pax, per entry
                let body = try consumeBody(size)
                paxPath = Self.paxValue(body, key: "path") ?? paxPath
                continue
            case 0x67, 0x4B:                             // 'g' pax global, 'K' long link
                _ = try consumeBody(size)
                continue
            default:
                let stored = Self.cString(block, 0, 100)
                let prefix = Self.cString(block, 340, 155)
                let joined = prefix.isEmpty ? stored : prefix + "/" + stored
                let name = paxPath ?? longName ?? joined
                return Header(name: name,
                              linkname: Self.cString(block, 157, 100),
                              size: size,
                              typeflag: typeflag)
            }
        }
    }

    /// Step over an entry's body without keeping it (directories, symlinks).
    func skipEntryBody(_ size: Int64) throws { _ = try consumeBody(size) }

    /// Read exactly `size` bytes of metadata and step over the padding.
    private func consumeBody(_ size: Int64) throws -> [UInt8] {
        var body = [UInt8]()
        var remaining = size
        while remaining > 0 {
            let take = Int(min(remaining, Int64(LinuxEnvironmentPackager.window)))
            let bytes = try readSome(take)
            if bytes.isEmpty { throw PackagerError.truncated }
            body.append(contentsOf: bytes)
            remaining -= Int64(bytes.count)
        }
        try align(size)
        return body
    }

    /// Pull `key=` out of a pax record, which is `LEN key=value\n`.
    private static func paxValue(_ body: [UInt8], key: String) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let range = text.range(of: " \(key)=") else { return nil }
        var value = String(text[range.upperBound...])
        if let end = value.firstIndex(of: "\n") { value = String(value[..<end]) }
        return value.isEmpty ? nil : value
    }

    /// Step over padding the writer added after a body of `count` bytes.
    func align(_ count: Int64) throws {
        let rem = Int(count % Int64(blockSize))
        guard rem != 0 else { return }
        _ = try readSome(blockSize - rem)
    }

    /// Up to `count` bytes; empty means the stream is over.
    func readSome(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        if let inflater { return try inflater.read(count) }
        let data = (try handle.read(upToCount: count)) ?? Data()
        return [UInt8](data)
    }

    /// The next full 512-byte block, or nil at a clean end of stream.
    private func readBlock() throws -> [UInt8]? {
        let block = try readSome(blockSize)
        if block.isEmpty { finished = true; return nil }
        if block.count < blockSize { throw PackagerError.truncated }
        return block
    }

    private static let blockSize = 512

    fileprivate static func cString(_ b: [UInt8], _ start: Int, _ max: Int) -> String {
        var end = start
        while end < start + max && end < b.count && b[end] != 0 { end += 1 }
        guard start < end else { return "" }
        return String(decoding: b[start ..< end], as: UTF8.self)
    }

    /// Octal, or GNU base-256 when the high bit of the first byte is set.
    fileprivate static func parseSize(_ field: [UInt8]) -> Int64 {
        guard let first = field.first else { return 0 }
        if first & 0x80 != 0 {
            var v: UInt64 = UInt64(first & 0x7f)
            for i in 1 ..< field.count { v = (v << 8) | UInt64(field[i]) }
            return Int64(v)
        }
        var value: Int64 = 0
        for c in field {
            if c == 0 || c == 0x20 { break }
            guard c >= 0x30 && c <= 0x37 else { break }
            value = value * 8 + Int64(c - 0x30)
        }
        return value
    }

    fileprivate static func checksumValid(_ h: [UInt8]) -> Bool {
        guard h.count == blockSize else { return false }
        var unsigned = 0
        var signed = 0
        for i in 0 ..< blockSize {
            if i >= 148 && i < 156 {
                unsigned += 0x20
                signed += 0x20
            } else {
                let byte = h[i]
                unsigned += Int(byte)
                signed += Int(Int8(bitPattern: byte))
            }
        }
        let stored = parseSize(Array(h[148 ..< 156]))
        return stored == Int64(unsigned) || stored == Int64(signed)
    }
}

/// Decompresses gzip, zlib or raw deflate on demand, so nothing above it knows
/// or cares whether the archive was compressed.
private final class Inflater {
    private var stream = z_stream()
    private let handle: FileHandle
    private let capacity = LinuxEnvironmentPackager.window
    private var raw = [UInt8]()
    private var rawOffset = 0
    private var rawEOF = false
    private var pending = [UInt8]()
    private var pendingOffset = 0
    private var ended = false
    private var started = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Returns up to `count` decompressed bytes; empty means end of stream.
    func read(_ count: Int) throws -> [UInt8] {
        if !started {
            started = true
            let rc = inflateInit2_(&stream, 47, ZLIB_VERSION,
                                   Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else { throw PackagerError.compression(rc) }
        }
        if pendingOffset >= pending.count, !ended {
            try fill()
        }
        guard pendingOffset < pending.count else { return [] }
        let take = min(count, pending.count - pendingOffset)
        let slice = Array(pending[pendingOffset ..< pendingOffset + take])
        pendingOffset += take
        if pendingOffset >= pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingOffset = 0
        }
        return slice
    }

    func close() {
        guard started else { return }
        inflateEnd(&stream)
        started = false
        ended = true
    }

    private func fill() throws {
        var out = [UInt8](repeating: 0, count: capacity)
        while pending.isEmpty && !ended {
            if rawOffset >= raw.count {
                if rawEOF { ended = true; return }
                let chunk = (try handle.read(upToCount: capacity)) ?? Data()
                if chunk.isEmpty {
                    rawEOF = true
                    // Fall through: there may still be buffered output.
                    if raw.isEmpty { ended = true; return }
                } else {
                    raw = [UInt8](chunk)
                    rawOffset = 0
                }
            }

            var rc: Int32 = Z_OK
            let consumed: Int
            let produced: Int
            out.withUnsafeMutableBytes { outBuf in
                raw.withUnsafeMutableBufferPointer { inBuf in
                    stream.next_in = inBuf.baseAddress!.advanced(by: rawOffset)
                    stream.avail_in = UInt32(raw.count - rawOffset)
                    stream.next_out = outBuf.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = UInt32(capacity)
                    rc = inflate(&stream, Z_NO_FLUSH)
                }
            }
            consumed = (raw.count - rawOffset) - Int(stream.avail_in)
            produced = capacity - Int(stream.avail_out)
            if consumed > 0 { rawOffset += consumed }
            if produced > 0 { pending.append(contentsOf: out[0 ..< produced]) }

            if rc == Z_STREAM_END {
                ended = true
                return
            }
            if rc == Z_BUF_ERROR {
                if produced == 0 && consumed == 0 {
                    if rawEOF { ended = true; return }
                    throw PackagerError.compression(rc)
                }
                continue
            }
            if rc != Z_OK { throw PackagerError.compression(rc) }
        }
    }
}
