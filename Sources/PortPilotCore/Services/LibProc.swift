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
    public static func listAllPids() -> [pid_t] {
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(bufferSize))
        let actualSize = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard actualSize > 0 else { return [] }
        let count = Int(actualSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count))
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
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXCOMLEN) + 1)
        defer { nameBuffer.deallocate() }

        let length = proc_name(pid, nameBuffer, UInt32(MAXCOMLEN) + 1)
        guard length > 0 else { return nil }
        return String(cString: nameBuffer)
    }

    // MARK: - Process Path

    /// Returns the full executable path for a PID, or nil on failure.
    public static func processPath(pid: pid_t) -> String? {
        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }

        let length = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: pathBuffer)
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

    // MARK: - Helpers

    /// Returns true if the given file descriptor is a socket.
    public static func isSocket(_ fd: proc_fdinfo) -> Bool {
        fd.proc_fdtype == PROX_FDTYPE_SOCKET
    }
}
