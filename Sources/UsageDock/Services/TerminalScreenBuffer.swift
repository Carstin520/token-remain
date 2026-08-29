import Foundation

/// Claude Code 输出的是终端的增量绘制指令，不是可直接拼接的日志文本。
/// 这里保留固定 PTY 的 cell 状态与真实滚屏历史；列跳转只移动光标，绝不
/// 擅自清空跨过的 cell，否则 diff repaint 没重画的字形仍会再次丢失。
struct TerminalScreenBuffer {
    private enum Cell: Equatable {
        case empty
        case glyph(String)
        case continuation
    }

    let columns: Int
    let rows: Int

    private var grid: [[Cell]]
    private var scrollback: [String] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor: (row: Int, column: Int)?

    init(columns: Int = 80, rows: Int = 60) {
        precondition(columns > 0 && rows > 0)
        self.columns = columns
        self.rows = rows
        grid = Array(
            repeating: Array(repeating: .empty, count: columns),
            count: rows
        )
    }

    static func reconstruct(
        _ data: Data,
        columns: Int = 80,
        rows: Int = 60
    ) -> String {
        var screen = TerminalScreenBuffer(columns: columns, rows: rows)
        screen.write(data)
        return screen.renderedText
    }

    mutating func write(_ data: Data) {
        let bytes = Array(data)
        var index = 0

        while index < bytes.count {
            switch bytes[index] {
            case 0x1B:
                consumeEscape(in: bytes, index: &index)
            case 0x0D:
                cursorColumn = 0
                index += 1
            case 0x0A:
                // PTY 输出通常是 CRLF；测试和异常退出片段也可能只留下 LF。
                // 两者都必须落到下一行起点，不能让逻辑文本逐行向右漂移。
                cursorColumn = 0
                lineFeed()
                index += 1
            case 0x08:
                cursorColumn = max(0, cursorColumn - 1)
                index += 1
            case 0x09:
                cursorColumn = min(columns, ((cursorColumn / 8) + 1) * 8)
                index += 1
            case 0x00...0x1F, 0x7F:
                index += 1
            default:
                let start = index
                while index < bytes.count,
                      bytes[index] != 0x1B,
                      bytes[index] > 0x1F,
                      bytes[index] != 0x7F {
                    index += 1
                }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                text.forEach { put($0) }
            }
        }
    }

    var renderedText: String {
        var lines = scrollback + grid.map(renderLine)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private mutating func consumeEscape(in bytes: [UInt8], index: inout Int) {
        guard index + 1 < bytes.count else {
            index = bytes.count
            return
        }

        switch bytes[index + 1] {
        case 0x5B: // CSI: ESC [
            consumeCSI(in: bytes, index: &index)
        case 0x5D: // OSC: ESC ] ... BEL / ST
            index += 2
            skipControlString(in: bytes, index: &index, alsoStopsAtBell: true)
        case 0x50, 0x58, 0x5E, 0x5F: // DCS / SOS / PM / APC
            index += 2
            skipControlString(in: bytes, index: &index, alsoStopsAtBell: false)
        case 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F: // 字符集选择
            index = min(bytes.count, index + 3)
        case 0x37: // DECSC
            savedCursor = (cursorRow, min(cursorColumn, columns - 1))
            index += 2
        case 0x38: // DECRC
            if let savedCursor {
                cursorRow = savedCursor.row
                cursorColumn = savedCursor.column
            }
            index += 2
        case 0x44: // IND
            lineFeed()
            index += 2
        case 0x4D: // RI
            reverseIndex()
            index += 2
        case 0x63: // RIS
            reset()
            index += 2
        default:
            // SGR 之外的单字符转义对额度文本没有可见字形；未知项必须整项
            // 跳过，不能把控制码尾字节误写进屏幕。
            index += 2
        }
    }

    private mutating func consumeCSI(in bytes: [UInt8], index: inout Int) {
        let parameterStart = index + 2
        var finalIndex = parameterStart
        while finalIndex < bytes.count,
              !(0x40...0x7E).contains(bytes[finalIndex]) {
            finalIndex += 1
        }
        guard finalIndex < bytes.count else {
            index = bytes.count
            return
        }

        let rawParameters = String(
            decoding: bytes[parameterStart..<finalIndex],
            as: UTF8.self
        )
        let parameters = parsedParameters(rawParameters)
        let final = bytes[finalIndex]

        switch final {
        case 0x41: // CUU
            cursorRow = max(0, cursorRow - parameter(parameters, at: 0, default: 1))
        case 0x42: // CUD
            cursorRow = min(rows - 1, cursorRow + parameter(parameters, at: 0, default: 1))
        case 0x43: // CUF
            cursorColumn = min(columns - 1, cursorColumn + parameter(parameters, at: 0, default: 1))
        case 0x44: // CUB
            cursorColumn = max(0, cursorColumn - parameter(parameters, at: 0, default: 1))
        case 0x45: // CNL
            cursorRow = min(rows - 1, cursorRow + parameter(parameters, at: 0, default: 1))
            cursorColumn = 0
        case 0x46: // CPL
            cursorRow = max(0, cursorRow - parameter(parameters, at: 0, default: 1))
            cursorColumn = 0
        case 0x47: // CHA
            cursorColumn = clampedColumn(parameter(parameters, at: 0, default: 1) - 1)
        case 0x48, 0x66: // CUP / HVP
            cursorRow = clampedRow(parameter(parameters, at: 0, default: 1) - 1)
            cursorColumn = clampedColumn(parameter(parameters, at: 1, default: 1) - 1)
        case 0x4A: // ED
            eraseDisplay(parameter(parameters, at: 0, default: 0))
        case 0x4B: // EL
            eraseLine(parameter(parameters, at: 0, default: 0))
        case 0x64: // VPA
            cursorRow = clampedRow(parameter(parameters, at: 0, default: 1) - 1)
        case 0x73: // ANSI save cursor
            savedCursor = (cursorRow, min(cursorColumn, columns - 1))
        case 0x75: // ANSI restore cursor
            if let savedCursor {
                cursorRow = savedCursor.row
                cursorColumn = savedCursor.column
            }
        default:
            // SGR、OSC 已在各自分支消费；DEC mode、设备查询、光标样式和
            // 全屏 scroll-region 设置都不产生文本 cell，保持状态即可。
            break
        }
        index = finalIndex + 1
    }

    private func parsedParameters(_ raw: String) -> [Int?] {
        let value = raw.drop(while: { "?<=>".contains($0) })
        guard !value.isEmpty else { return [] }
        return value.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0)
        }
    }

    private func parameter(_ values: [Int?], at index: Int, default fallback: Int) -> Int {
        guard values.indices.contains(index), let value = values[index], value != 0 else {
            return fallback
        }
        return value
    }

    private mutating func skipControlString(
        in bytes: [UInt8],
        index: inout Int,
        alsoStopsAtBell: Bool
    ) {
        while index < bytes.count {
            if alsoStopsAtBell, bytes[index] == 0x07 {
                index += 1
                return
            }
            if bytes[index] == 0x1B,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x5C {
                index += 2
                return
            }
            index += 1
        }
    }

    private mutating func put(_ character: Character) {
        let width = Self.columnWidth(of: character)
        guard width > 0 else {
            appendZeroWidth(character)
            return
        }

        if cursorColumn >= columns || (width == 2 && cursorColumn == columns - 1) {
            cursorColumn = 0
            lineFeed()
        }

        clearOverlappingGlyph(atRow: cursorRow, column: cursorColumn)
        if width == 2 {
            clearOverlappingGlyph(atRow: cursorRow, column: cursorColumn + 1)
        }
        grid[cursorRow][cursorColumn] = .glyph(String(character))
        if width == 2 {
            grid[cursorRow][cursorColumn + 1] = .continuation
        }
        cursorColumn += width
    }

    private mutating func appendZeroWidth(_ character: Character) {
        var column = min(cursorColumn, columns) - 1
        while column >= 0 {
            switch grid[cursorRow][column] {
            case .glyph(let text):
                grid[cursorRow][column] = .glyph(text + String(character))
                return
            case .continuation, .empty:
                column -= 1
            }
        }
    }

    private mutating func clearOverlappingGlyph(atRow row: Int, column: Int) {
        guard grid[row].indices.contains(column) else { return }
        switch grid[row][column] {
        case .empty:
            return
        case .continuation:
            grid[row][column] = .empty
            if column > 0, case .glyph = grid[row][column - 1] {
                grid[row][column - 1] = .empty
            }
        case .glyph:
            grid[row][column] = .empty
            if column + 1 < columns, grid[row][column + 1] == .continuation {
                grid[row][column + 1] = .empty
            }
        }
    }

    private mutating func lineFeed() {
        if cursorRow == rows - 1 {
            scrollback.append(renderLine(grid[0]))
            grid.removeFirst()
            grid.append(Array(repeating: .empty, count: columns))
        } else {
            cursorRow += 1
        }
    }

    private mutating func reverseIndex() {
        if cursorRow == 0 {
            grid.removeLast()
            grid.insert(Array(repeating: .empty, count: columns), at: 0)
        } else {
            cursorRow -= 1
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 1:
            clear(row: cursorRow, columns: 0...min(cursorColumn, columns - 1))
        case 2:
            clear(row: cursorRow, columns: 0...(columns - 1))
        default:
            clear(row: cursorRow, columns: min(cursorColumn, columns - 1)...(columns - 1))
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 1:
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    clear(row: row, columns: 0...(columns - 1))
                }
            }
            clear(row: cursorRow, columns: 0...min(cursorColumn, columns - 1))
        case 2:
            for row in grid.indices {
                clear(row: row, columns: 0...(columns - 1))
            }
        case 3:
            scrollback.removeAll()
        default:
            clear(row: cursorRow, columns: min(cursorColumn, columns - 1)...(columns - 1))
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows {
                    clear(row: row, columns: 0...(columns - 1))
                }
            }
        }
    }

    private mutating func clear(row: Int, columns range: ClosedRange<Int>) {
        for column in range where grid[row].indices.contains(column) {
            clearOverlappingGlyph(atRow: row, column: column)
        }
    }

    private mutating func reset() {
        grid = Array(
            repeating: Array(repeating: .empty, count: columns),
            count: rows
        )
        scrollback.removeAll()
        cursorRow = 0
        cursorColumn = 0
        savedCursor = nil
    }

    private func renderLine(_ line: [Cell]) -> String {
        var result = ""
        for cell in line {
            switch cell {
            case .empty:
                result.append(" ")
            case .glyph(let text):
                result.append(text)
            case .continuation:
                break
            }
        }
        while result.last == " " {
            result.removeLast()
        }
        return result
    }

    private func clampedRow(_ value: Int) -> Int {
        min(rows - 1, max(0, value))
    }

    private func clampedColumn(_ value: Int) -> Int {
        min(columns - 1, max(0, value))
    }

    /// `String.count` 不能代表终端列宽：CJK/emoji 占两格，组合符占零格，
    /// block drawing 字符仍只占一格。按 grapheme cluster 计算可避免 ZWJ
    /// emoji 被每个 scalar 重复计宽。
    private static func columnWidth(of character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        if scalars.allSatisfy({ isZeroWidth($0) }) {
            return 0
        }
        if scalars.contains(where: { $0.value == 0xFE0F || $0.properties.isEmojiPresentation }) {
            return 2
        }
        if scalars.contains(where: isEastAsianWide) {
            return 2
        }
        return 1
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func isEastAsianWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             0x2E80...0x303E,
             0x3040...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
