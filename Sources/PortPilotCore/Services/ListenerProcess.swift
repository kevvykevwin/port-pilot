import Darwin
import Foundation

/// Owns exactly one scanner child. All state and nonblocking pipe reads are
/// confined to queue. Cancellation/timeout only signals this owned child.
final class ListenerProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PortPilot.lsof")
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var endedStreams: Set<Int32> = []
    private var stdout = Data()
    private var stderr = Data()
    private var continuation: CheckedContinuation<String, any Error>?
    private var cancelled = false
    private var finished = false
    private let timeout: TimeInterval
    private let outputLimit: Int

    init(executablePath: String, arguments: [String], timeout: TimeInterval, outputLimit: Int) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func run() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(PortScanError.cancelled))
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
        guard !cancelled else {
            finish(.failure(PortScanError.cancelled))
            return
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                self.drain(self.output.fileHandleForReading.fileDescriptor, isError: false)
                self.drain(self.errors.fileHandleForReading.fileDescriptor, isError: true)
                guard !self.finished else { return }
                let status = self.process.terminationStatus
                // lsof exits 1 with no output when no files match. Diagnostics or
                // partial output on a failed scan must still trigger fallback.
                if status == 0 || (status == 1 && self.stdout.isEmpty && self.stderr.isEmpty) {
                    self.finish(.success(String(decoding: self.stdout, as: UTF8.self)))
                } else {
                    self.finish(.failure(PortScanError.nonzeroExit(status)))
                }
            }
        }
        do {
            try process.run()
        } catch {
            finish(.failure(PortScanError.launchFailed))
            return
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        watch(output.fileHandleForReading, isError: false)
        watch(errors.fileHandleForReading, isError: true)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(PortScanError.timedOut))
        }
    }

    private func watch(_ handle: FileHandle, isError: Bool) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain(fd, isError: isError) }
        reader.setCancelHandler { try? handle.close() }
        readers[fd] = reader
        reader.resume()
    }

    private func drain(_ fd: Int32, isError: Bool) {
        guard !finished, !endedStreams.contains(fd) else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count == 0 {
                // An early-closed pipe remains readable at EOF. Suspend its
                // source to avoid spinning while the child is still running.
                endedStreams.insert(fd)
                readers[fd]?.suspend()
                return
            }
            guard count > 0 else { return }
            guard stdout.count + stderr.count + count <= outputLimit else {
                finish(.failure(PortScanError.outputLimitExceeded))
                return
            }
            if isError { stderr.append(contentsOf: buffer.prefix(count)) }
            else { stdout.append(contentsOf: buffer.prefix(count)) }
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        // Cancellation can arrive before start installs its continuation.
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.terminationHandler = nil
        for (fd, reader) in readers {
            if endedStreams.contains(fd) { reader.resume() }
            reader.cancel()
        }
        if readers.isEmpty {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        continuation.resume(with: result)
    }
}
