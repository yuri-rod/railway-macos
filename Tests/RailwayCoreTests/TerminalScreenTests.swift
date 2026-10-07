import XCTest
import Darwin
import TerminalProcess
@testable import RailwayCore

final class TerminalScreenTests: XCTestCase {
    func testCombiningFloodRetainsBoundedCellAndContinuesParsing() {
        var screen = TerminalScreen(rows: 4, columns: 12)
        _ = screen.feed(Data(("a" + String(repeating: "\u{301}", count: 10_000)).utf8))
        XCTAssertLessThanOrEqual(screen.cells[0][0].text.utf8.count, 64)
        XCTAssertEqual(screen.column, 1)
        XCTAssertEqual(screen.feed(Data("b\u{1B}[6n".utf8)), [Data("\u{1B}[1;3R".utf8)])
        XCTAssertEqual(screen.cells[0][1].text, "b")
    }
    func testSplitCombiningScalarsPreserveNormalUnicodeAndBoundWideCell() {
        var screen = TerminalScreen(rows: 2, columns: 4)
        for byte in "e\u{301}界".utf8 { _ = screen.feed(Data([byte])) }
        XCTAssertEqual(screen.cells[0][0].text, "e\u{301}")
        XCTAssertFalse(screen.outputTruncated)
        for byte in String(repeating: "\u{200D}", count: 1000).utf8 { _ = screen.feed(Data([byte])) }
        XCTAssertLessThanOrEqual(screen.cells[0][1].text.utf8.count, 64)
        XCTAssertEqual(screen.cells[0][2].text, "")
        XCTAssertTrue(screen.outputTruncated)
    }
    func testOverflowRemainsBoundedAcrossAlternateResizeScrollbackAndReset() {
        var screen = TerminalScreen(rows: 2, columns: 4)
        let flood = "a" + String(repeating: "\u{301}", count: 100)
        _ = screen.feed(Data(flood.utf8))
        _ = screen.feed(Data("\u{1B}[?1049h".utf8))
        _ = screen.feed(Data(flood.utf8))
        screen.resize(rows: 3, columns: 5)
        _ = screen.feed(Data("\u{1B}[?1049l".utf8))
        XCTAssertLessThanOrEqual(screen.cells[0][0].text.utf8.count, 64)
        for _ in 0..<2002 { _ = screen.feed(Data(("\r" + flood + "\n").utf8)) }
        XCTAssertEqual(screen.scrollback.count, 2000)
        XCTAssertTrue(screen.scrollback.allSatisfy { $0.utf8.count <= 5 * 64 })
        _ = screen.feed(Data("\u{1B}csafe".utf8))
        XCTAssertTrue(screen.outputTruncated)
        XCTAssertTrue(screen.text.hasPrefix("safe"))
        XCTAssertFalse(TerminalScreen().outputTruncated)
    }
    func testInitialGeometryUsesResizeLimits() {
        let screen = TerminalScreen(rows: Int.max, columns: Int.max)
        XCTAssertEqual(screen.rows, 200)
        XCTAssertEqual(screen.columns, 400)
    }
    func testSplitUTF8ColorsAndCursorAddressing() {
        var screen = TerminalScreen(rows: 4, columns: 12)
        let bytes = Array("Olá 世界".utf8)
        for byte in bytes { _ = screen.feed(Data([byte])) }
        XCTAssertEqual(screen.cells[0][2].text, "á")
        XCTAssertEqual(screen.cells[0][4].text, "世")
        XCTAssertEqual(screen.cells[0][6].text, "界")
        _ = screen.feed(Data("\u{1B}[2;3H\u{1B}[31;1mERR\u{1B}[0m".utf8))
        XCTAssertEqual(screen.cells[1][2].text, "E")
        XCTAssertEqual(screen.cells[1][2].foreground, TerminalScreen.palette(1))
        XCTAssertTrue(screen.cells[1][2].bold)
    }
    func testAlternateScreenRestoresShellAfterTerminalApplication() {
        var screen = TerminalScreen(rows: 4, columns: 10)
        _ = screen.feed(Data("shell\u{1B}[?1049h\u{1B}[2J\u{1B}[Heditor\u{1B}[?25l".utf8))
        XCTAssertTrue(screen.text.hasPrefix("editor")); XCTAssertFalse(screen.cursorVisible)
        _ = screen.feed(Data("\u{1B}[?1049l\u{1B}[?25h".utf8))
        XCTAssertTrue(screen.text.hasPrefix("shell")); XCTAssertTrue(screen.cursorVisible)
    }
    func testScrollingRegionPreservesApplicationHeader() {
        var screen = TerminalScreen(rows: 4, columns: 10)
        _ = screen.feed(Data("HEADER\u{1B}[2;4r\u{1B}[4;1Hbottom\n".utf8))
        XCTAssertTrue(screen.cells[0].map(\.text).joined().hasPrefix("HEADER"))
        XCTAssertTrue(screen.cells[2].map(\.text).joined().hasPrefix("bottom"))
    }
    func testResizeBoundsCursorAndAnswersPositionQuery() {
        var screen = TerminalScreen(rows: 24, columns: 80)
        _ = screen.feed(Data("\u{1B}[24;80H".utf8)); screen.resize(rows: 4, columns: 10)
        let replies = screen.feed(Data("\u{1B}[6n".utf8))
        XCTAssertEqual(replies, [Data("\u{1B}[4;10R".utf8)])
        XCTAssertEqual(screen.cells.count, 4); XCTAssertEqual(screen.cells[0].count, 10)
    }
    func testOSCClipboardCommandDoesNotChangeTextOrProduceReply() {
        var screen = TerminalScreen()
        let replies = screen.feed(Data("\u{1B}]52;c;c2VjcmV0\u{7}safe".utf8))
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(screen.text.hasPrefix("safe"))
    }
    func testInteractiveVimUsesNativeScreenAndExitsWithoutWritingFiles() throws {
        let arguments = ["/usr/bin/vi", "-u", "NONE", "-i", "NONE", "-n", "-N"]
        let argv = arguments.map { strdup($0) } + [nil]
        let env = [strdup("TERM=xterm-256color"), strdup("PATH=/usr/bin:/bin"), strdup("LANG=en_US.UTF-8"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var fd: Int32 = -1
        let pid = "/usr/bin/vi".withCString { path in argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { vars in railway_terminal_start(path, args.baseAddress, vars.baseAddress, 24, 80, &fd) } } }
        guard pid > 0 else { XCTFail("Unable to start vi in a PTY"); return }
        defer { close(fd); kill(pid, SIGTERM); var status: Int32 = 0; waitpid(pid, &status, 0) }
        var screen = TerminalScreen()
        func receive(for seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 20)
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 {
                    for reply in screen.feed(Data(bytes.prefix(count))) { _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
                }
            } while Date() < deadline
        }
        receive(for: 0.2)
        let insert = Data("iNative terminal check".utf8)
        _ = insert.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        receive(for: 0.3)
        XCTAssertTrue(screen.text.contains("Native terminal check"))
        let quit = Data("\u{1B}:q!\r".utf8)
        _ = quit.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        receive(for: 0.2)
    }
    func testRealPTYRunsInteractiveProcessAndReportsExit() throws {
        let strings = ["/bin/sh", "-c", #"test -t 0 && printf '\033[32mPTY OK\033[0m\\n'"#]
        let argv = strings.map { strdup($0) } + [nil]
        let env = [strdup("TERM=xterm-256color"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var fd: Int32 = -1
        let pid = strings[0].withCString { path in argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { vars in railway_terminal_start(path, args.baseAddress, vars.baseAddress, 24, 80, &fd) } } }
        XCTAssertGreaterThan(pid, 0)
        guard pid > 0 else { return }
        defer { close(fd) }
        XCTAssertEqual(railway_terminal_resize(fd, 40, 120), 0)
        var captured = Data(), status: Int32 = -1
        let deadline = Date().addingTimeInterval(3)
        repeat {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 20)
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { captured.append(contentsOf: buffer.prefix(count)) }
            status = Int32(railway_terminal_status(pid))
        } while status < 0 && Date() < deadline
        if status < 0 { kill(pid, SIGTERM); var code: Int32 = 0; waitpid(pid, &code, 0) }
        XCTAssertEqual(status, 0)
        var screen = TerminalScreen(); _ = screen.feed(captured)
        XCTAssertTrue(screen.text.contains("PTY OK"))
        XCTAssertEqual(screen.cells[0][0].foreground, TerminalScreen.palette(2))
    }
}
