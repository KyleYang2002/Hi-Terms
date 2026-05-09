import os.log

enum UILog {
    static let input = Logger(subsystem: "com.hiterms.ui", category: "input")
    static let view = Logger(subsystem: "com.hiterms.ui", category: "view")
    static let hyperlink = Logger(subsystem: "com.hiterms.ui", category: "hyperlink")
}
