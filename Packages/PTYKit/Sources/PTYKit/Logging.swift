import os.log

public enum PTYLog {
    public static let lifecycle = Logger(subsystem: "com.hiterms.pty", category: "lifecycle")
    public static let io = Logger(subsystem: "com.hiterms.pty", category: "io")
}
