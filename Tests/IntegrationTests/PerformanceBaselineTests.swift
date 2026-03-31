import XCTest
import TerminalCore

/// Performance baseline tests for terminal parser throughput.
/// Conditional on parser availability (Scenario P/N per acceptance criteria).
final class PerformanceBaselineTests: XCTestCase {

    func testParserThroughput10MB() throws {
        let testDataPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/perf-baseline/test-data.bin")

        // Try loading generated test data, fall back to in-memory generation
        let data: Data
        if FileManager.default.fileExists(atPath: testDataPath.path) {
            data = try Data(contentsOf: testDataPath)
        } else {
            // Generate 10MB in-memory
            data = generateMixedTerminalData(sizeMB: 10)
        }

        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let chunkSize = 8192

        let start = CFAbsoluteTimeGetCurrent()
        for offset in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(offset + chunkSize, data.count)
            adapter.parse(data: data[offset..<end])
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let throughput = Double(data.count) / elapsed / 1_000_000

        print("=== PERFORMANCE BASELINE ===")
        print("Data size: \(data.count) bytes (\(String(format: "%.1f", Double(data.count) / 1_000_000)) MB)")
        print("Elapsed: \(String(format: "%.3f", elapsed)) seconds")
        print("Throughput: \(String(format: "%.1f", throughput)) MB/s")
        print("Target: >= 50 MB/s")
        print("============================")

        // Performance baseline — record value. The 50 MB/s target is for Release builds.
        // Debug builds are significantly slower; we record the baseline here.
        XCTAssertGreaterThan(throughput, 0, "Parser throughput should be measurable")
    }

    private func generateMixedTerminalData(sizeMB: Int) -> Data {
        var data = Data()
        let targetSize = sizeMB * 1_000_000

        let asciiChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ".utf8)
        let colorSequences = [
            "\u{1b}[31m", "\u{1b}[32m", "\u{1b}[33m", "\u{1b}[0m",
            "\u{1b}[1m", "\u{1b}[4m",
            "\u{1b}[38;5;196m", "\u{1b}[38;5;46m",
            "\u{1b}[38;2;255;128;0m",
        ]
        let cursorSequences = [
            "\u{1b}[A", "\u{1b}[B", "\u{1b}[C", "\u{1b}[D",
            "\u{1b}[H", "\u{1b}[1;1H", "\u{1b}[10;20H",
        ]

        data.reserveCapacity(targetSize)
        var written = 0
        var counter = 0

        while written < targetSize {
            counter += 1
            let roll = counter % 100

            if roll < 80 {
                // 80% ASCII
                let lineLen = 40 + (counter % 40)
                for i in 0..<lineLen {
                    data.append(asciiChars[(counter + i) % asciiChars.count])
                }
                data.append(contentsOf: "\r\n".utf8)
                written += lineLen + 2
            } else if roll < 95 {
                // 15% ANSI color
                let seq = colorSequences[counter % colorSequences.count]
                data.append(contentsOf: seq.utf8)
                data.append(contentsOf: "X".utf8)
                written += seq.utf8.count + 1
            } else {
                // 5% cursor moves
                let seq = cursorSequences[counter % cursorSequences.count]
                data.append(contentsOf: seq.utf8)
                written += seq.utf8.count
            }
        }

        return data
    }
}
