import os.log

public enum TerminalLog {
    public static let parser = Logger(subsystem: "com.hiterms.terminal", category: "parser")
    public static let buffer = Logger(subsystem: "com.hiterms.terminal", category: "buffer")
}
