import Foundation

/// Configuration for launching a PTY process.
public struct PTYConfiguration: Sendable {
    public var shellPath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var initialWindowSize: (cols: UInt16, rows: UInt16)
    public var workingDirectory: String?
    public var terminalType: String

    public init(
        shellPath: String? = nil,
        arguments: [String] = ["-l"],
        environment: [String: String] = [:],
        initialWindowSize: (cols: UInt16, rows: UInt16) = (80, 25),
        workingDirectory: String? = nil,
        terminalType: String = "xterm-256color"
    ) {
        self.shellPath = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.arguments = arguments
        self.environment = environment
        self.initialWindowSize = initialWindowSize
        self.workingDirectory = workingDirectory
        self.terminalType = terminalType
    }

    public static let `default` = PTYConfiguration()
}
