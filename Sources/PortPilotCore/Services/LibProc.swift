import Darwin
import Foundation

// Constants from Darwin headers
private let PROC_PIDLISTFDS: Int32 = 1
private let PROC_PIDTBSDINFO: Int32 = 3
private let PROC_PIDFDSOCKETINFO: Int32 = 3
private let PROX_FDTYPE_SOCKET: UInt32 = 2

public enum LibProc {

    // MARK: - PID Enumeration

    /// Returns all active PIDs on the system.
    ///
    /// `proc_listallpids` returns the PID count, not bytes — Apple's libproc
    /// wrapper divides by `sizeof(int)` internally before returning. Dividing
    /// again truncates the result to ~25% on systems with 4-byte `pid_t`.
    public static func listAllPids() -> [pid_t] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        let actualCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard actualCount > 0 else { return [] }
        return Array(pids.prefix(Int(actualCount)))
    }

    // MARK: - File Descriptors

    /// Returns the list of file descriptors for a given PID.
    public static func listFileDescriptors(pid: pid_t) -> [proc_fdinfo] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let fdCount = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)

        let actualSize = fds.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<proc_fdinfo>.size)
            )
        }
        guard actualSize > 0 else { return [] }
        let actualCount = Int(actualSize) / MemoryLayout<proc_fdinfo>.size
        return Array(fds.prefix(actualCount))
    }

    // MARK: - Socket Info

    /// Returns socket info for a specific file descriptor, or nil on failure.
    public static func socketInfo(pid: pid_t, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = MemoryLayout<socket_fdinfo>.size

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, ptr, Int32(size))
        }
        guard result == size else { return nil }
        return info
    }

    // MARK: - Process Name

    /// Returns the process name for a PID, or nil on failure.
    public static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Process Path

    /// Returns the full executable path for a PID, or nil on failure.
    public static func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - BSD Info (start time)

    /// Returns the process start time for a PID, or nil on failure.
    public static func processStartTime(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
        }
        guard result == size else { return nil }

        let seconds = TimeInterval(info.pbi_start_tvsec)
        let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds + microseconds)
    }

    /// Only retain the script identity, never command text or environment values.
    public static func processScriptPath(pid: pid_t) -> String? {
        guard let path = processPath(pid: pid),
              ProcessClassifier.isRuntimeExecutable(path) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1024 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var offset = MemoryLayout<Int32>.size
        while offset < size && data[offset] != 0 { offset += 1 } // executable pathname
        while offset < size && data[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < size && data[offset] != 0 { offset += 1 }
            guard offset < size else { return nil }
            arguments.append(String(decoding: data[start..<offset], as: UTF8.self))
            offset += 1
        }
        return scriptPath(arguments: arguments, cwd: processCwd(pid: pid))
    }

    static func scriptPath(arguments: [String], cwd: String?) -> String? {
        // Conservative: unsupported switches stay unresolved rather than treating
        // a switch argument, eval string, or application argument as a script.
        guard arguments.count > 1 else { return nil }
        let candidate = arguments[1]
        guard !candidate.hasPrefix("-"),
              ["js", "mjs", "cjs", "ts", "py", "rb", "php"].contains((candidate as NSString).pathExtension)
        else { return nil }
        if candidate.hasPrefix("/") { return URL(fileURLWithPath: candidate).standardizedFileURL.path }
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).appendingPathComponent(candidate).standardizedFileURL.path
    }

    public static func processCwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, 9, 0, &info, Int32(size)) == size else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Helpers

    /// Returns true if the given file descriptor is a socket.
    public static func isSocket(_ fd: proc_fdinfo) -> Bool {
        fd.proc_fdtype == PROX_FDTYPE_SOCKET
    }
}
