import Foundation
import Testing
@testable import UsageDock

@Suite("Terminal screen reconstruction")
struct TerminalScreenBufferTests {
    @Test("Absolute and relative cursor movement address terminal cells")
    func positionsCursor() {
        let bytes = "\u{001B}[3;3HX\u{001B}[2CY\u{001B}[3DZ\u{001B}[2AA\u{001B}[1BB"
        let text = TerminalScreenBuffer.reconstruct(Data(bytes.utf8), columns: 8, rows: 3)

        #expect(text == "    A\n     B\n  XZ Y")
    }

    @Test("A column jump preserves cells omitted by a diff repaint")
    func columnJumpKeepsOldCell() {
        let bytes = "\u{001B}[3GResets\r\u{001B}[3GRese\u{001B}[8Gs"
        let text = TerminalScreenBuffer.reconstruct(Data(bytes.utf8), columns: 12, rows: 2)

        #expect(text == "  Resets")
    }

    @Test("CR, LF, and backspace update the cursor instead of becoming text")
    func handlesBasicCursorControls() {
        let text = TerminalScreenBuffer.reconstruct(
            Data("abc\rZ\n12\u{0008}X".utf8),
            columns: 8,
            rows: 3
        )

        #expect(text == "Zbc\n1X")
    }

    @Test("EL modes erase only their addressed line ranges")
    func erasesLineRanges() {
        let bytes = """
        \u{001B}[1;1Habcdef\u{001B}[2;1Hghijkl\u{001B}[3;1Hmnopqr\u{001B}[1;3H\u{001B}[1K\u{001B}[2;3H\u{001B}[K\u{001B}[3;1H\u{001B}[2K
        """
        let text = TerminalScreenBuffer.reconstruct(Data(bytes.utf8), columns: 6, rows: 3)

        #expect(text == "   def\ngh")
    }

    @Test("ED modes honor the cursor boundary and full-screen clear")
    func erasesDisplayRanges() {
        var screen = TerminalScreenBuffer(columns: 6, rows: 3)
        screen.write(Data("\u{001B}[1;1Habcdef\u{001B}[2;1Hghijkl\u{001B}[3;1Hmnopqr".utf8))
        screen.write(Data("\u{001B}[2;3H\u{001B}[J".utf8))
        #expect(screen.renderedText == "abcdef\ngh")

        screen.write(Data("\u{001B}[2;1Hghijkl\u{001B}[3;1Hmnopqr\u{001B}[2;3H\u{001B}[1J".utf8))
        #expect(screen.renderedText == "\n   jkl\nmnopqr")

        screen.write(Data("\u{001B}[2J".utf8))
        #expect(screen.renderedText.isEmpty)
    }

    @Test("Lines leaving the top remain available in scrollback")
    func retainsScrolledLines() {
        let text = TerminalScreenBuffer.reconstruct(
            Data("one\ntwo\nthree".utf8),
            columns: 8,
            rows: 2
        )

        #expect(text == "one\ntwo\nthree")
    }

    @Test("CJK and emoji occupy two columns while block glyphs occupy one")
    func usesTerminalColumnWidths() {
        let bytes = "A中B█🙂C\u{001B}[8GZ"
        let text = TerminalScreenBuffer.reconstruct(Data(bytes.utf8), columns: 10, rows: 2)

        #expect(text == "A中B█🙂Z")
    }

    @Test("Styling, title, and charset controls never become visible text")
    func skipsNonprintingControls() {
        let bytes = "\u{001B}]0;hidden\u{0007}\u{001B}(0\u{001B}[31mVisible\u{001B}[0m"
        let text = TerminalScreenBuffer.reconstruct(Data(bytes.utf8), columns: 20, rows: 2)

        #expect(text == "Visible")
    }
}

/// 这些夹具是 Claude CLI 2.1.238 在 80×60 PTY 上写出的原始字节流。
/// 测试必须从终端状态重建，而不能预先清洗成一份迎合正则的文本快照。
@Suite("Claude 2.1.238 terminal captures")
struct ClaudeTerminalCaptureRegressionTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    private func shanghai() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        return calendar
    }

    private func capturedAt() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: "2026-08-26T09:10:00Z"))
    }

    @Test("A split reset word is reconstructed into a complete session row")
    func reconstructsSplitSessionReset() throws {
        let data = try fixture("probe_capture")
        let text = ClaudeCLIUsageParser.reconstructedTerminalText(data)
        let quota = try ClaudeCLIUsageParser.parse(
            data,
            now: try capturedAt(),
            calendar: try shanghai()
        )

        #expect(text.contains("Resets 8:40pm (Asia/Shanghai)"))
        #expect(ClaudeCLIUsageParser.hasCompleteUsage(in: data))
        #expect(quota.primary.usedPercent == 11)
        #expect(
            quota.primary.resetsAt
                == ISO8601DateFormatter().date(from: "2026-08-26T12:40:00Z")
        )
    }

    @Test(
        "Every real environment capture reconstructs a complete usage screen",
        arguments: [
            "probe_capture",
            "probe_capture_guienv",
            "probe_guienv_plus_proxy",
            "probe_shellenv_minus_proxy"
        ]
    )
    func reconstructsRealCapture(_ name: String) throws {
        let data = try fixture(name)
        let text = ClaudeCLIUsageParser.reconstructedTerminalText(data)
        let quota = try ClaudeCLIUsageParser.parse(
            data,
            now: try capturedAt(),
            calendar: try shanghai()
        )

        #expect(!text.contains("\u{001B}"))
        #expect(text.localizedCaseInsensitiveContains("Current session"))
        #expect(ClaudeCLIUsageParser.hasCompleteUsage(in: data))
        #expect(quota.secondary != nil)
    }
}
