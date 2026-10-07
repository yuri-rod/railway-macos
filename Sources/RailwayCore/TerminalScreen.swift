import Foundation

public struct TerminalCell: Sendable, Equatable {
    public var text = " "
    public var foreground: UInt32 = 0xE6E4ED
    public var background: UInt32 = 0x12111B
    public var bold = false
    public var inverse = false
}
public struct TerminalScreen: Sendable {
    public private(set) var rows: Int
    public private(set) var columns: Int
    public private(set) var cells: [[TerminalCell]]
    public private(set) var row = 0
    public private(set) var column = 0
    public private(set) var cursorVisible = true
    public private(set) var applicationCursor = false
    public private(set) var bracketedPaste = false
    public private(set) var title = "Terminal"
    public private(set) var scrollback: [String] = []
    public private(set) var outputTruncated = false
    private var style = TerminalCell()
    private var state = 0
    private var escape = ""
    private var utf8: [UInt8] = []
    private var lineDrawing = false
    private var savedCursor = (0, 0)
    private var savedScreen: [[TerminalCell]]?
    private var top = 0
    private var bottom: Int
    private var wrap = true
    private var pendingWrap = false
    public init(rows: Int = 24, columns: Int = 80) {
        self.rows = max(2, min(rows, 200)); self.columns = max(2, min(columns, 400)); bottom = self.rows - 1
        cells = Array(repeating: Array(repeating: TerminalCell(), count: self.columns), count: self.rows)
    }
    public var text: String { cells.map { $0.map(\.text).joined() }.joined(separator: "\n") }
    public mutating func resize(rows: Int, columns: Int) {
        let height = max(2, min(rows, 200)), width = max(2, min(columns, 400))
        func resized(_ old: [[TerminalCell]]) -> [[TerminalCell]] {
            (0..<height).map { y in (0..<width).map { x in y < old.count && x < old[y].count ? old[y][x] : TerminalCell() } }
        }
        cells = resized(cells)
        if let savedScreen { self.savedScreen = resized(savedScreen) }
        self.rows = height; self.columns = width; top = 0; bottom = height - 1
        row = min(row, height - 1); column = min(column, width - 1); pendingWrap = false
    }
    public mutating func feed(_ data: Data) -> [Data] {
        var replies: [Data] = []
        for byte in data {
            if state == 3 {
                if byte == 7 { finishTitle(); state = 0 }
                else if byte == 27 { state = 4 }
                else if escape.utf8.count < 4096 { escape.append(Character(UnicodeScalar(byte))) }
                continue
            }
            if state == 4 { finishTitle(); state = byte == 92 ? 0 : 1; continue }
            if state == 1 {
                state = 0
                switch byte {
                case 91: state = 2; escape = ""
                case 93: state = 3; escape = ""
                case 55: savedCursor = (row, column)
                case 56: row = min(savedCursor.0, rows - 1); column = min(savedCursor.1, columns - 1)
                case 68: linefeed()
                case 77: if row == top { cells.insert(blankLine(), at: top); cells.remove(at: bottom + 1) } else { row = max(0, row - 1) }
                case 69: column = 0; linefeed()
                case 99:
                    let truncated = outputTruncated
                    self = TerminalScreen(rows: rows, columns: columns)
                    outputTruncated = truncated
                case 40, 41: state = 5
                default: break
                }
                continue
            }
            if state == 5 { lineDrawing = byte == 48; state = 0; continue }
            if state == 2 {
                if (0x40...0x7E).contains(byte) {
                    if let reply = control(Character(UnicodeScalar(byte))) { replies.append(Data(reply.utf8)) }
                    state = 0; escape = ""
                } else if escape.count < 256 { escape.append(Character(UnicodeScalar(byte))) }
                else { state = 0; escape = "" }
                continue
            }
            switch byte {
            case 27: state = 1; utf8 = []
            case 13: column = 0; pendingWrap = false
            case 10, 11, 12: linefeed()
            case 8: column = max(0, column - 1); pendingWrap = false
            case 9: column = min(columns - 1, ((column / 8) + 1) * 8); pendingWrap = false
            case 0...31, 127: break
            default:
                utf8.append(byte)
                let first = utf8[0]
                let expected = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
                if utf8.count >= expected {
                    for scalar in String(decoding: utf8, as: UTF8.self).unicodeScalars { put(scalar) }
                    utf8 = []
                }
            }
        }
        return replies
    }
    private mutating func finishTitle() {
        let pieces = escape.split(separator: ";", maxSplits: 1)
        if pieces.count == 2, ["0", "2"].contains(String(pieces[0])) { title = String(pieces[1]) }
        escape = ""
    }
    private func blankLine() -> [TerminalCell] { Array(repeating: TerminalCell(background: style.background), count: columns) }
    private mutating func linefeed() {
        pendingWrap = false
        if row == bottom { scrollUp() } else { row = min(rows - 1, row + 1) }
    }
    private mutating func scrollUp() {
        if top == 0, savedScreen == nil {
            scrollback.append(cells[0].map(\.text).joined())
            if scrollback.count > 2000 { scrollback.removeFirst(scrollback.count - 2000) }
        }
        cells.remove(at: top); cells.insert(blankLine(), at: bottom)
    }
    private mutating func put(_ scalar: UnicodeScalar) {
        let value = scalar.value
        let combining = CharacterSet.nonBaseCharacters.contains(scalar) || value == 0x200D
        let wide = (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value) || (0xFE10...0xFE6F).contains(value) || (0xFF01...0xFF60).contains(value) || (0xFFE0...0xFFE6).contains(value) || (0x20000...0x3FFFD).contains(value) || scalar.properties.isEmojiPresentation
        let width = combining ? 0 : wide ? 2 : 1
        if width == 0 {
            var previous = pendingWrap ? column : column - 1
            if previous >= 0, cells[row][previous].text.isEmpty { previous -= 1 }
            if previous >= 0 {
                if cells[row][previous].text.utf8.count + String(scalar).utf8.count <= 64 {
                    cells[row][previous].text.unicodeScalars.append(scalar)
                } else { outputTruncated = true }
            }
            return
        }
        if pendingWrap, wrap { column = 0; linefeed() }
        if width == 2, column == columns - 1, wrap { column = 0; linefeed() }
        let graphics: [UnicodeScalar: String] = ["q": "─", "x": "│", "l": "┌", "k": "┐", "m": "└", "j": "┘", "t": "├", "u": "┤", "w": "┬", "v": "┴", "n": "┼"]
        var cell = style; cell.text = lineDrawing ? graphics[scalar] ?? String(scalar) : String(scalar); cells[row][column] = cell
        if width == 2, column + 1 < columns { cells[row][column + 1] = TerminalCell(text: "", foreground: style.foreground, background: style.background, bold: style.bold) }
        let next = column + width
        pendingWrap = next >= columns; column = min(columns - 1, next)
    }
    private mutating func control(_ final: Character) -> String? {
        let privateMode = escape.hasPrefix("?")
        let raw = privateMode ? String(escape.dropFirst()) : escape
        let values = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let n = min(1000, max(1, values.first ?? 1))
        pendingWrap = false
        switch final {
        case "A": row = max(0, row - n)
        case "B", "e": row = min(rows - 1, row + n)
        case "C", "a": column = min(columns - 1, column + n)
        case "D": column = max(0, column - n)
        case "E": row = min(rows - 1, row + n); column = 0
        case "F": row = max(0, row - n); column = 0
        case "G", "`": column = min(columns - 1, n - 1)
        case "d": row = min(rows - 1, n - 1)
        case "H", "f": row = min(rows - 1, n - 1); column = min(columns - 1, max(1, values.count > 1 ? values[1] : 1) - 1)
        case "J":
            let mode = values.first ?? 0
            if mode == 2 || mode == 3 { cells = Array(repeating: blankLine(), count: rows); if mode == 3 { scrollback = [] } }
            else if mode == 0 { for y in row..<rows { for x in (y == row ? column : 0)..<columns { cells[y][x] = TerminalCell(background: style.background) } } }
            else if mode == 1 { for y in 0...row { for x in 0...(y == row ? column : columns - 1) { cells[y][x] = TerminalCell(background: style.background) } } }
        case "K":
            let mode = values.first ?? 0
            let range = mode == 1 ? 0...column : mode == 2 ? 0...(columns - 1) : column...(columns - 1)
            for x in range { cells[row][x] = TerminalCell(background: style.background) }
        case "m": rendition(values)
        case "r":
            let first = max(0, n - 1), last = min(rows - 1, max(1, values.count > 1 && values[1] > 0 ? values[1] : rows) - 1)
            if first < last { top = first; bottom = last; row = 0; column = 0 }
        case "S": for _ in 0..<min(n, bottom - top + 1) { scrollUp() }
        case "T": for _ in 0..<min(n, bottom - top + 1) { cells.insert(blankLine(), at: top); cells.remove(at: bottom + 1) }
        case "L": if (top...bottom).contains(row) { for _ in 0..<min(n, bottom - row + 1) { cells.insert(blankLine(), at: row); cells.remove(at: bottom + 1) } }
        case "M": if (top...bottom).contains(row) { for _ in 0..<min(n, bottom - row + 1) { cells.remove(at: row); cells.insert(blankLine(), at: bottom) } }
        case "P": for _ in 0..<min(n, columns - column) { cells[row].remove(at: column); cells[row].append(TerminalCell(background: style.background)) }
        case "@": for _ in 0..<min(n, columns - column) { cells[row].insert(TerminalCell(background: style.background), at: column); cells[row].removeLast() }
        case "X": for x in column..<min(columns, column + n) { cells[row][x] = TerminalCell(background: style.background) }
        case "s": savedCursor = (row, column)
        case "u": row = min(savedCursor.0, rows - 1); column = min(savedCursor.1, columns - 1)
        case "n": if values.first == 6 { return "\u{1B}[\(row + 1);\(column + 1)R" }; if values.first == 5 { return "\u{1B}[0n" }
        case "c": return "\u{1B}[?1;2c"
        case "h", "l":
            if privateMode {
                for mode in values {
                    let enabled = final == "h"
                    switch mode {
                    case 1: applicationCursor = enabled
                    case 7: wrap = enabled
                    case 25: cursorVisible = enabled
                    case 2004: bracketedPaste = enabled
                    case 47, 1047, 1049:
                        if enabled, savedScreen == nil { savedScreen = cells; savedCursor = (row, column); cells = Array(repeating: blankLine(), count: rows); row = 0; column = 0 }
                        else if !enabled, let saved = savedScreen { cells = saved; savedScreen = nil; row = min(savedCursor.0, rows - 1); column = min(savedCursor.1, columns - 1) }
                    default: break
                    }
                }
            }
        default: break
        }
        return nil
    }
    private mutating func rendition(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0: style = TerminalCell()
            case 1: style.bold = true
            case 22: style.bold = false
            case 7: style.inverse = true
            case 27: style.inverse = false
            case 39: style.foreground = TerminalCell().foreground
            case 49: style.background = TerminalCell().background
            case 30...37: style.foreground = Self.palette(value - 30)
            case 40...47: style.background = Self.palette(value - 40)
            case 90...97: style.foreground = Self.palette(value - 90 + 8)
            case 100...107: style.background = Self.palette(value - 100 + 8)
            case 38, 48:
                var color: UInt32?
                if index + 2 < values.count, values[index + 1] == 5 { color = Self.palette(values[index + 2]); index += 2 }
                else if index + 4 < values.count, values[index + 1] == 2 {
                    color = UInt32(clamping: min(255, max(0, values[index + 2]))) << 16 | UInt32(clamping: min(255, max(0, values[index + 3]))) << 8 | UInt32(clamping: min(255, max(0, values[index + 4])))
                    index += 4
                }
                if let color { if value == 38 { style.foreground = color } else { style.background = color } }
            default: break
            }
            index += 1
        }
    }
    public static func palette(_ index: Int) -> UInt32 {
        let basic: [UInt32] = [0x12111B, 0xE06C75, 0x70C69B, 0xE5C07B, 0x61AFEF, 0xB78DF1, 0x56B6C2, 0xD8D5E0, 0x686375, 0xFF8790, 0x97E6B9, 0xFFDC97, 0x8ACFFF, 0xD8ABFF, 0x80DDE5, 0xFFFFFF]
        let index = max(0, min(255, index))
        if index < 16 { return basic[index] }
        if index >= 232 { let c = UInt32(8 + (index - 232) * 10); return c << 16 | c << 8 | c }
        let n = index - 16, levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        return levels[n / 36] << 16 | levels[(n / 6) % 6] << 8 | levels[n % 6]
    }
}
