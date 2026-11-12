import Darwin
import Foundation
import Security

/// Notices when the code this process was launched from is deleted, moved, or changed on disk.
///
/// Why the app cares: its keyboard tap is an active event tap, and WindowServer drops everything
/// such a tap hands back once macOS can no longer verify the tap owner's code signature at the
/// path it was launched from. That happens when the app bundle is rebuilt, edited, moved, or
/// deleted while the app runs. Keys and clicks then stop working system-wide, so the user cannot
/// quit the app; it has to notice and get out of the way by itself.
///
/// Not thread-safe: create it, check it, and watch it from one queue.
public final class BinaryWatch {
    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Changes whenever a file is replaced, written, or has its metadata touched (ctime can't be set back).
    private struct Stamp: Equatable {
        let file: FileID
        let size: off_t
        let changed: timespec

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.file == b.file && a.size == b.size
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    /// The signed code: the app bundle, or a bare executable.
    public let code: URL
    /// The executable file inside `code` (the same file for a bare executable).
    public let executable: String
    /// The executable, then (for a bundle) every file and folder in the bundle: a folder's stamp
    /// changes when an entry is added or removed, so new files are noticed too.
    private let stamped: [String]
    private let originalFile: FileID?
    /// The creation-time code's hash (a validation takes a few milliseconds). If that validation
    /// fails, it is retried on the next checks that still find the files unchanged since creation.
    private var originalHash: Data?
    /// Stamps last confirmed to belong to the original code; while they match, nothing is re-hashed.
    private var verified: [Stamp?]
    /// Validations of unchanged files that failed to give a creation-time hash; capped, after which
    /// the code is treated as unsigned rather than re-hashed on every check.
    private var baselineAttempts = 1
    private static let maxBaselineAttempts = 3

    private var source: DispatchSourceFileSystemObject?

    /// Watches this process: its app bundle when it runs from one, otherwise its executable.
    public convenience init() {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        self.init(code: bundle.pathExtension == "app" ? bundle : exe, executable: exe.path)
    }

    public init(code: URL, executable: String) {
        self.code = code
        self.executable = executable
        var stamped = [executable]
        if code.path != executable {
            stamped.append(code.path)
            let entries = FileManager.default.enumerator(atPath: code.path)?.compactMap { $0 as? String } ?? []
            stamped += entries.sorted().map { code.appendingPathComponent($0).path }.filter { $0 != executable }
        }
        self.stamped = stamped
        verified = stamped.map(Self.stamp(at:))
        originalFile = verified[0]?.file
        originalHash = Self.validHash(of: code)
    }

    /// False once the executable path names another file or none, or the code on disk is no longer
    /// the code that was there at creation: a different signature, or none that validates (checked
    /// twice, 0.2 s apart, to ride out a transient read error). Code whose signature could not be
    /// validated before the first change (unsigned) counts as changed on any write or metadata
    /// change. Always true when the executable could not be found at creation (nothing to compare).
    ///
    /// Cheap while nothing changed (a `stat` per bundle entry); after a change it validates the
    /// signature, which hashes the code, and may wait 0.2 s for the second try.
    public var isIntact: Bool {
        guard let originalFile else { return true }
        guard Self.stamp(at: executable)?.file == originalFile else { return false }
        let now = stamped.map(Self.stamp(at:))
        if now == verified {
            if originalHash == nil, baselineAttempts < Self.maxBaselineAttempts {
                baselineAttempts += 1
                originalHash = Self.validHash(of: code)
            }
            return true
        }
        guard let originalHash else { return false }
        var hash = Self.validHash(of: code)
        if hash == nil {
            usleep(200_000)
            hash = Self.validHash(of: code)
        }
        guard hash == originalHash else { return false }
        verified = now // touched (metadata, same bytes) but still the same code
        return true
    }

    /// Calls `onEvent` on `queue` whenever the executable file is deleted, renamed, written, or
    /// revoked. The event only says something happened; check `isIntact` to decide. Changes that
    /// leave no trace on that file (a parent folder moved, Info.plist edited) are only caught by
    /// checking `isIntact`, so callers should also poll it.
    public func watch(queue: DispatchQueue = .main, onEvent: @escaping () -> Void) {
        guard source == nil, originalFile != nil else { return }
        let fd = open(executable, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.delete, .rename, .revoke, .write, .extend], queue: queue)
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }

    private static func stamp(at path: String) -> Stamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Stamp(file: FileID(device: st.st_dev, inode: st.st_ino), size: st.st_size, changed: st.st_ctimespec)
    }

    /// The code directory hash of the code at `url`, or nil when it is missing, unsigned, or fails
    /// validation (executable, Info.plist, and sealed resources).
    private static func validHash(of url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash
    }
}
