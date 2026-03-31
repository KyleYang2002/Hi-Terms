import Foundation

/// Errors from PTY operations.
public enum PTYError: Error, LocalizedError {
    case forkFailed(errno: Int32)
    case execFailed(path: String, errno: Int32)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case processNotRunning

    public var errorDescription: String? {
        switch self {
        case .forkFailed(let errno):
            return "forkpty failed: \(String(cString: strerror(errno)))"
        case .execFailed(let path, let errno):
            return "exec failed for \(path): \(String(cString: strerror(errno)))"
        case .readFailed(let errno):
            return "PTY read failed: \(String(cString: strerror(errno)))"
        case .writeFailed(let errno):
            return "PTY write failed: \(String(cString: strerror(errno)))"
        case .processNotRunning:
            return "PTY process is not running"
        }
    }
}
