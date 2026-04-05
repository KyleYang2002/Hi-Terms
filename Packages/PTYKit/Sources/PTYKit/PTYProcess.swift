import Foundation
import Darwin
import os.log

/// Manages a single PTY instance: fd lifecycle, read/write, process state.
///
/// Uses `forkpty` to create the PTY pair and `DispatchIO` for non-blocking reads
/// on a per-PTY serial queue.
public final class PTYProcess {
    public private(set) var pid: pid_t = -1
    public private(set) var masterFD: Int32 = -1
    private let queue: DispatchQueue
    private var dispatchSource: DispatchSourceRead?
    private var dataHandler: ((Data) -> Void)?
    private var asyncContinuation: AsyncStream<Data>.Continuation?

    public init(configuration: PTYConfiguration) throws {
        self.queue = DispatchQueue(label: "com.hiterms.pty.\(UUID().uuidString)")

        var winsize = winsize(
            ws_row: configuration.initialWindowSize.rows,
            ws_col: configuration.initialWindowSize.cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let fd = forkpty(&masterFD, nil, nil, &winsize)

        guard fd >= 0 else {
            throw PTYError.forkFailed(errno: errno)
        }

        if fd == 0 {
            // Child process
            if let workDir = configuration.workingDirectory {
                chdir(workDir)
            }

            // Merge environment
            for (key, value) in configuration.environment {
                setenv(key, value, 1)
            }

            // Build C args array
            let allArgs = [configuration.shellPath] + configuration.arguments
            let cArgs = allArgs.map { strdup($0) } + [nil]
            defer { cArgs.forEach { free($0) } }

            execvp(configuration.shellPath, cArgs)
            // If we get here, exec failed
            _exit(1)
        }

        // Parent process — forkpty returns child PID to parent
        self.pid = fd

        PTYLog.lifecycle.info("PTY created: pid=\(self.pid), fd=\(self.masterFD)")
        setupReading()
    }

    private func setupReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = Darwin.read(self.masterFD, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                self.dataHandler?(data)
                self.asyncContinuation?.yield(data)
            } else if bytesRead == 0 {
                // True EOF — shell exited
                self.asyncContinuation?.finish()
                source.cancel()
                PTYLog.lifecycle.info("PTY read EOF: pid=\(self.pid)")
            } else {
                // bytesRead == -1 — read error
                let err = errno
                if err == EINTR || err == EAGAIN { return }
                PTYLog.io.error("PTY read error: pid=\(self.pid), errno=\(err)")
                self.asyncContinuation?.finish()
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.masterFD)
        }
        source.resume()
        self.dispatchSource = source
    }

    /// Sets the data handler for the internal pipeline path.
    /// Called on the per-PTY serial queue.
    public func setDataHandler(_ handler: @escaping (Data) -> Void) {
        queue.async { self.dataHandler = handler }
    }

    /// Returns an `AsyncStream` for reading PTY output.
    /// Intended for tests and external consumers.
    public func read() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.queue.async {
                self.asyncContinuation = continuation
            }
        }
    }

    /// Writes data to the PTY master fd.
    /// Handles partial writes and EINTR retries.
    public func write(data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var remaining = buffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(masterFD, ptr + offset, remaining)
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    PTYLog.io.error("PTY write failed: pid=\(self.pid), errno=\(err)")
                    return
                }
                offset += written
                remaining -= written
            }
        }
    }

    /// Resizes the PTY window.
    public func resize(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        kill(pid, SIGWINCH)
    }

    /// Terminates the PTY process and reaps the child to avoid zombies.
    public func terminate() {
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        var status: Int32 = 0
        // Give child 100ms to exit gracefully
        usleep(100_000)
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 {
            // Still running — force kill
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        dispatchSource?.cancel()
        PTYLog.lifecycle.info("PTY terminated: pid=\(self.pid)")
    }

    deinit {
        if pid > 0 {
            terminate()
        }
    }
}
