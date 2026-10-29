import Darwin
import Foundation

/// Accesso minimale a `lstat(2)`: non segue mai i collegamenti simbolici.
struct FileStat: Sendable, Equatable {
    let mode: mode_t
    let device: dev_t
    let inode: UInt64
    let linkCount: UInt16
    let allocatedBytes: Int64
    let logicalBytes: Int64

    var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
    var isSymbolicLink: Bool { (mode & S_IFMT) == S_IFLNK }
    var isRegularFile: Bool { (mode & S_IFMT) == S_IFREG }

    init(_ st: stat) {
        mode = st.st_mode
        device = st.st_dev
        inode = UInt64(st.st_ino)
        linkCount = UInt16(truncatingIfNeeded: st.st_nlink)
        allocatedBytes = Int64(st.st_blocks) * 512
        logicalBytes = Int64(st.st_size)
    }

    /// `nil` se il percorso non esiste o non è accessibile.
    static func lstat(_ path: String) -> FileStat? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return FileStat(st)
    }

    /// Variante relativa a un file descriptor di directory, senza seguire symlink.
    static func at(_ directoryFD: Int32, name: String) -> FileStat? {
        var st = stat()
        guard fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return FileStat(st)
    }

    static func lastErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}

enum PathTools {
    /// Percorso canonico (risolve i collegamenti degli antenati, es. `/var` → `/private/var`).
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Restituisce la home reale dell'utente (non quella di un eventuale container sandbox).
    static func userHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
