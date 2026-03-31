import os.log

public enum RendererLog {
    public static let frame = Logger(subsystem: "com.hiterms.renderer", category: "frame")
    public static let perf = Logger(subsystem: "com.hiterms.renderer", category: "perf")
}
