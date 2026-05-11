import Foundation
import Darwin
import ArgumentParser

// MARK: - Theme/Style

struct Style {
    var fg: Int?
    var bold: Bool = false
    var dim: Bool = false
}

struct Theme {
    let name: String
    var prompt: Style
    var header: Style
    var success: Style
    var error: Style
    var accent: Style
    var dim: Style
    var uuid: Style
    var cursor: Style

    static let dark = Theme(
        name: "dark",
        prompt: Style(fg: 96, bold: true),
        header: Style(fg: 94, bold: true),
        success: Style(fg: 32),
        error: Style(fg: 31, bold: true),
        accent: Style(fg: 94),
        dim: Style(fg: 90),
        uuid: Style(fg: 36),
        cursor: Style(fg: 93, bold: true)
    )

    static let light = Theme(
        name: "light",
        prompt: Style(fg: 34, bold: true),
        header: Style(fg: 34, bold: true),
        success: Style(fg: 32),
        error: Style(fg: 31, bold: true),
        accent: Style(fg: 34),
        dim: Style(fg: 90),
        uuid: Style(fg: 36),
        cursor: Style(fg: 33, bold: true)
    )
}

var currentTheme: Theme = {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "-g", "AppleInterfaceStyle"]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let style = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return style == "Dark" ? .dark : .dark
}()

func styled(_ text: String, _ style: Style) -> String {
    var codes: [Int] = []
    if style.bold { codes.append(1) }
    if style.dim { codes.append(2) }
    if let fg = style.fg { codes.append(fg) }
    if codes.isEmpty { return text }
    return "\u{1B}[\(codes.map(String.init).joined(separator: ";"))m\(text)\u{1B}[0m"
}

// MARK: - Key

enum Key {
    case char(Character)
    case up, down, left, right
    case enter, backspace, tab
    case ctrlC, ctrlD
    case escape, delete
    case unknown
}

// MARK: - Terminal raw mode

var gSavedTerm = termios()

func restoreTermHandler(sig: Int32) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &gSavedTerm)
    _exit(128 + sig)
}

func enableRawMode() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    tcgetattr(STDIN_FILENO, &gSavedTerm)

    var raw = gSavedTerm
    raw.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
    raw.c_oflag &= ~tcflag_t(OPOST)
    raw.c_cflag |= tcflag_t(CS8)
    raw.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
    raw.c_cc.0 = 0
    raw.c_cc.1 = 1
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

func disableRawMode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &gSavedTerm)
}

func writeStr(_ s: String) {
    let data = Data(s.utf8)
    data.withUnsafeBytes { buf in
        _ = write(STDOUT_FILENO, buf.baseAddress, buf.count)
    }
}

func writeLine(_ s: String = "") {
    writeStr(s + "\r\n")
}

func terminalSize() -> (width: Int, height: Int) {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 else { return (80, 24) }
    return (Int(ws.ws_col), Int(ws.ws_row))
}

func clearLine() {
    writeStr("\r\u{1B}[K")
}

// MARK: - Key reading

func readKey() -> Key {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return .unknown }

    switch byte {
    case 0x03: return .ctrlC
    case 0x04: return .ctrlD
    case 0x09: return .tab
    case 0x0A, 0x0D: return .enter
    case 0x7F, 0x08: return .backspace
    case 0x1B:
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 15) > 0 else { return .escape }
        var seq: [UInt8] = []
        for _ in 0..<4 {
            var pfd2 = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd2, 1, 5) > 0 else { break }
            var b: UInt8 = 0
            guard read(STDIN_FILENO, &b, 1) == 1 else { break }
            seq.append(b)
        }
        if seq == [0x5B, 0x41] { return .up }
        if seq == [0x5B, 0x42] { return .down }
        if seq == [0x5B, 0x43] { return .right }
        if seq == [0x5B, 0x44] { return .left }
        if seq == [0x5B, 0x33, 0x7E] { return .delete }
        return .escape
    default:
        if byte < 128, let s = UnicodeScalar(UInt32(byte)).map({ Character($0) }) {
            return .char(s)
        }
        return .unknown
    }
}

// MARK: - Line split/parse

func splitLine(_ line: String) -> [String] {
    var parts: [String] = []
    var cur = ""
    var inQ = false
    for c in line {
        switch c {
        case "\"":
            inQ.toggle()
        case " " where !inQ:
            if !cur.isEmpty { parts.append(cur); cur = "" }
        default:
            cur.append(c)
        }
    }
    if !cur.isEmpty { parts.append(cur) }
    return parts
}

struct ParsedCmd {
    let name: String
    var args: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
}

func parseCommand(_ line: String) -> ParsedCmd? {
    let parts = splitLine(line)
    guard !parts.isEmpty else { return nil }
    guard parts[0].hasPrefix("/") else { return nil }
    let name = String(parts[0].dropFirst())
    var pc = ParsedCmd(name: name)
    var i = 1
    while i < parts.count {
        let p = parts[i]
        if p.hasPrefix("--") {
            let key = String(p.dropFirst(2))
            if i + 1 < parts.count, !parts[i + 1].hasPrefix("--") {
                pc.options[key] = parts[i + 1]
                i += 2
            } else {
                pc.flags.insert(key)
                i += 1
            }
        } else {
            pc.args.append(p)
            i += 1
        }
    }
    return pc
}

// MARK: - Line editor

struct LineEditor {
    var buffer: String = ""
    var history: [String] = []
    var historyIdx: Int = -1
    var tabCycle: [String] = []
    var tabIdx: Int = 0
    let prompt: String

    static let commands = [
        "new", "list", "search", "aisearch", "get",
        "current", "action", "tag", "flag", "folder",
        "help", "exit"
    ]

    init(prompt: String = "> ") {
        self.prompt = prompt
    }

    mutating func reset() {
        buffer = ""
        historyIdx = history.count
        tabCycle = []
        tabIdx = 0
    }

    mutating func addChar(_ c: Character) {
        buffer.append(c)
        tabCycle = []
    }

    mutating func deleteChar() {
        guard !buffer.isEmpty else { return }
        buffer.removeLast()
        tabCycle = []
    }

    mutating func historyPrev() {
        guard !history.isEmpty else { return }
        if historyIdx == history.count { historyIdx = history.count - 1 }
        else if historyIdx > 0 { historyIdx -= 1 }
        buffer = history[historyIdx]
        tabCycle = []
    }

    mutating func historyNext() {
        guard historyIdx < history.count else { return }
        historyIdx += 1
        if historyIdx >= history.count {
            buffer = ""
            historyIdx = history.count
        } else {
            buffer = history[historyIdx]
        }
        tabCycle = []
    }

    mutating func tabComplete() {
        if tabCycle.isEmpty {
            let lastToken = buffer.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if lastToken.hasPrefix("/") {
                let partial = String(lastToken.dropFirst())
                tabCycle = Self.commands.filter { $0.hasPrefix(partial) }.map { "/" + $0 }
            } else if !buffer.contains(" ") {
                let partial = lastToken
                tabCycle = Self.commands.filter { $0.hasPrefix(partial) }.map { "/" + $0 }
            }
            tabIdx = 0
        }
        if tabCycle.isEmpty { return }
        let completion = tabCycle[tabIdx % tabCycle.count]
        tabIdx += 1

        let parts = buffer.split(separator: " ", omittingEmptySubsequences: false)
        if parts.isEmpty || (parts.count == 1 && buffer.hasPrefix("/")) || (parts.count == 1 && !buffer.contains(" ")) {
            buffer = String(completion) + " "
        } else if let last = parts.last, last.hasPrefix("/") || !buffer.contains(" ") {
            let rest = parts.dropLast().map(String.init)
            if rest.isEmpty && !buffer.hasSuffix(" ") {
                buffer = String(completion) + " "
            } else {
                buffer = (rest + [completion]).joined(separator: " ") + " "
            }
        }
    }

    mutating func readLine() -> String {
        let styledPrompt = styled(prompt, currentTheme.prompt)
        writeStr(styledPrompt + buffer)
        while true {
            let key = readKey()
            switch key {
            case .char(let c):
                addChar(c)
                clearLine()
                writeStr(styledPrompt + buffer)
            case .backspace:
                deleteChar()
                clearLine()
                writeStr(styledPrompt + buffer)
            case .up:
                historyPrev()
                clearLine()
                writeStr(styledPrompt + buffer)
            case .down:
                historyNext()
                clearLine()
                writeStr(styledPrompt + buffer)
            case .tab:
                tabComplete()
                clearLine()
                writeStr(styledPrompt + buffer)
                if tabCycle.count > 1 {
                    writeLine()
                    let suggestions = tabCycle.map { styled("/" + $0, currentTheme.accent) }.joined(separator: "  ")
                    writeStr("  " + suggestions)
                    clearLine()
                    writeStr(styledPrompt + buffer)
                }
            case .enter:
                writeLine()
                let line = buffer
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    history.append(line)
                }
                reset()
                return line
            case .ctrlC, .ctrlD:
                writeLine("^C")
                return "/exit"
            default:
                break
            }
        }
    }
}

// MARK: - Compose mode

func runCompose(options: [String: String], flags: Set<String>) {
    writeLine(styled("── Compose your draft (type /end on a blank line to save, /cancel to abort) ──", currentTheme.header))
    var lines: [String] = []
    var line = ""

    func refreshLine() {
        clearLine()
        writeStr(line)
    }

    composeLoop: while true {
        let key = readKey()
        switch key {
        case .char(let c):
            line.append(c)
            writeStr(String(c))
        case .backspace:
            guard !line.isEmpty else { break }
            if line.count == 1 {
                line = ""
                clearLine()
            } else {
                line.removeLast()
                writeStr("\u{8} \u{8}")
            }
        case .enter:
            writeLine()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "/end" {
                break composeLoop
            }
            if trimmed.hasSuffix("/end") {
                let before = String(trimmed.dropLast(4)).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { lines.append(before) }
                break composeLoop
            }
            if trimmed == "/cancel" {
                writeLine(styled("Cancelled.", currentTheme.dim))
                return
            }
            lines.append(line)
            line = ""
        case .ctrlC, .ctrlD:
            writeLine()
            writeLine(styled("Cancelled.", currentTheme.dim))
            return
        default:
            break
        }
    }

    let content = lines.joined(separator: "\n")
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        writeLine(styled("Empty draft — not created.", currentTheme.dim))
        return
    }

    do {
        var tags: String? = nil
        if let t = options["tags"] { tags = t }
        let folder = options["folder"]
        let flagged = flags.contains("flag")
        let uuid = try DraftsBridge.createDraft(content: content, tags: tags, folder: folder, flagged: flagged)
        writeLine("\(styled("Created:", currentTheme.success)) \(styled(uuid, currentTheme.uuid))")
    } catch DraftsError.notAuthorized {
        writeLine("AppleScript not authorized. Trying URL scheme...")
        if let r = DraftsBridge.createViaURL(content: content, tags: options["tags"], folder: options["folder"], flagged: flags.contains("flag")) {
            writeLine("\(styled("Created", currentTheme.success)) \(r)")
        } else {
            writeLine("Failed to create draft.")
        }
    } catch {
        writeLine("\(styled("Error:", currentTheme.error)) \(error)")
    }
}

// MARK: - List navigator + view mode

func viewContent(_ content: String, label: String) {
    let (width, height) = terminalSize()
    let lines = content.components(separatedBy: "\n").map { line -> String in
        if line.count > width - 2 { return String(line.prefix(width - 2)) }
        return line
    }
    let maxOffset = max(0, lines.count - (height - 3))
    var offset = 0
    var prevCount = 0

    func render() {
        let end = min(offset + (height - 3), lines.count)
        let count = end - offset + 1
        if prevCount > 0 {
            writeStr("\u{1B}[\(prevCount)A")
        }
        writeStr("\r\u{1B}[K")
        writeLine(styled("\u{2500}\u{2500} \(label) (\u{2191}/\u{2193} scroll, Esc back) \u{2500}\u{2500}", currentTheme.header))
        for i in offset..<end {
            writeStr("\r\u{1B}[K")
            writeLine(" " + lines[i])
        }
        prevCount = count
    }

    render()
    while true {
        let key = readKey()
        switch key {
        case .up where offset > 0:
            offset -= 1
            render()
        case .down where offset < maxOffset:
            offset += 1
            render()
        case .escape, .char("q"):
            return
        default:
            break
        }
    }
}

func navigateList(drafts: [(uuid: String, content: String)], label: String) {
    let (width, height) = terminalSize()
    let visible = max(height - 4, 3)
    var idx = 0
    var offset = 0
    var prevCount = 0

    func render() {
        let end = min(offset + visible, drafts.count)
        let count = end - offset + 1
        if prevCount > 0 {
            writeStr("\u{1B}[\(prevCount)A")
        }
        writeStr("\r\u{1B}[K")
        writeLine(styled("\u{2500}\u{2500} \(label) (\u{2191}/\u{2193} select, Enter view, q back) \u{2500}\u{2500}", currentTheme.header))
        for i in offset..<end {
            writeStr("\r\u{1B}[K")
            let d = drafts[i]
            let preview = d.content.prefix(width - 10).replacingOccurrences(of: "\n", with: " ")
            let cursor = i == idx ? styled("\u{2192} ", currentTheme.cursor) : "  "
            let uuid = styled(String(d.uuid.prefix(8)), currentTheme.uuid)
            writeLine("\(cursor)\(uuid)  \(preview)")
        }
        prevCount = count
    }

    render()
    while true {
        let key = readKey()
        switch key {
        case .up:
            guard idx > 0 else { break }
            idx -= 1
            if idx < offset { offset = idx }
            render()
        case .down:
            guard idx < drafts.count - 1 else { break }
            idx += 1
            if idx >= offset + visible { offset = idx - visible + 1 }
            render()
        case .enter:
            let d = drafts[idx]
            do {
                let full = try DraftsBridge.getDraft(uuid: d.uuid)
                viewContent(full.content ?? full.preview, label: full.uuid)
            } catch {
                viewContent(d.content, label: d.uuid)
            }
            render()
        case .escape, .char("q"):
            return
        default:
            break
        }
    }
}

// MARK: - REPL

func showHelp() {
    let a = currentTheme.accent
    writeLine(styled("Commands:", currentTheme.header))
    writeLine("  \(styled("/new", a)) [--tags <t>] [--flag]     Compose and create a draft")
    writeLine("  \(styled("/list", a)) [--tag <t>] [--folder <f>] [--flagged] [--search <q>] [--limit <n>]")
    writeLine("  \(styled("/search", a)) <q> [--folder <f>] [--limit <n>]")
    writeLine("  \(styled("/aisearch", a)) <q> [--limit <n>]")
    writeLine("  \(styled("/get", a)) <uuid>")
    writeLine("  \(styled("/current", a))")
    writeLine("  \(styled("/action", a)) <name> [--uuid <uuid>]")
    writeLine("  \(styled("/tag", a)) <uuid> <tag> ...")
    writeLine("  \(styled("/flag", a)) <uuid> [--unflag]")
    writeLine("  \(styled("/folder", a)) <uuid> <inbox|archive|trash>")
    writeLine("  \(styled("/help", a))  \(styled("/exit", a))")
}

func runREPL() throws {
    enableRawMode()
    defer { disableRawMode() }

    writeLine(styled("DraftScript interactive. Type /help for commands. /exit or ^C to quit.", currentTheme.header))
    writeLine("")

    var editor = LineEditor()

    while true {
        let input = editor.readLine()

        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        guard let cmd = parseCommand(trimmed) else {
            if trimmed.hasPrefix("/") {
                writeLine("\(styled("Unknown command:", currentTheme.error)) \(trimmed)")
            } else {
                writeLine(styled("Type /help for commands", currentTheme.dim))
            }
            continue
        }

        switch cmd.name {
        case "exit", "quit":
            writeLine(styled("Goodbye.", currentTheme.header))
            return

        case "help":
            showHelp()

        case "new":
            runCompose(options: cmd.options, flags: cmd.flags)

        case "list":
            do {
                let tag = cmd.options["tag"]
                let folder = cmd.options["folder"]
                let flagged = cmd.flags.contains("flagged") ? true : nil
                let search = cmd.options["search"]
                let limit = Int(cmd.options["limit"] ?? "") ?? 50
                let drafts = try DraftsBridge.listDrafts(tag: tag, folder: folder, flagged: flagged, search: search, limit: limit)
                if drafts.isEmpty {
                    writeLine(styled("No drafts found.", currentTheme.dim))
                } else {
                    for d in drafts { writeLine(d.description) }
                    writeLine(styled("---", currentTheme.dim))
                    writeLine(styled("\(drafts.count) draft(s)", currentTheme.dim))
                }
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "search":
            guard let query = cmd.args.first ?? cmd.options["query"] else {
                writeLine(styled("Usage: /search <query> [--folder <f>] [--limit <n>]", currentTheme.dim))
                break
            }
            do {
                let folder = cmd.options["folder"]
                let limit = Int(cmd.options["limit"] ?? "") ?? 50
                let drafts = try DraftsBridge.listDrafts(tag: nil, folder: folder, flagged: nil, search: query, limit: limit)
                if drafts.isEmpty {
                    writeLine(styled("No drafts matching \"\(query)\"", currentTheme.dim))
                } else if drafts.count > 1 {
                    let items: [(uuid: String, content: String)] = drafts.map { ($0.uuid, $0.content ?? $0.preview) }
                    navigateList(drafts: items, label: "Results for \"\(query)\"")
                } else {
                    for d in drafts { writeLine(d.description) }
                    writeLine(styled("---", currentTheme.dim))
                    writeLine(styled("\(drafts.count) match(es)", currentTheme.dim))
                }
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "aisearch":
            guard let query = cmd.args.first ?? cmd.options["query"] else {
                writeLine(styled("Usage: /aisearch <query> [--limit <n>]", currentTheme.dim))
                break
            }
            let limit = Int(cmd.options["limit"] ?? "") ?? 50
            guard LLMService.isAvailable else {
                writeLine(styled("Ollama is not available.", currentTheme.error) + "\r\nInstall from https://ollama.com then pull: ollama pull gemma4")
                break
            }
            writeStr(styled("Fetching drafts... ", currentTheme.accent))
            do {
                let drafts = try DraftsBridge.fetchAllDrafts(limit: limit)
                writeLine(styled("\(drafts.count) found.", currentTheme.dim))
                guard !drafts.isEmpty else { writeLine(styled("No drafts to search.", currentTheme.dim)); break }

                writeLine(styled("Querying LLM (\(LLMService.model))...", currentTheme.accent))
                let response = try LLMService.searchDrafts(query: query, drafts: drafts)
                writeLine("")
                writeLine(response)
                writeLine("")

                let items: [(uuid: String, content: String)] = drafts
                navigateList(drafts: items, label: "All drafts")
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "get":
            guard let uuid = cmd.args.first else {
                writeLine(styled("Usage: /get <uuid>", currentTheme.dim))
                break
            }
            do {
                let d = try DraftsBridge.getDraft(uuid: uuid)
                writeLine("\(styled("UUID:", currentTheme.dim))   \(styled(d.uuid, currentTheme.uuid))")
                writeLine("\(styled("Flagged:", currentTheme.dim)) \(d.flagged)")
                writeLine("\(styled("Folder:", currentTheme.dim))  \(d.folder)")
                writeLine(styled("---", currentTheme.dim))
                writeLine(d.content ?? d.preview)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "current":
            do {
                let d = try DraftsBridge.getCurrentDraft()
                writeLine("\(styled("UUID:", currentTheme.dim))   \(styled(d.uuid, currentTheme.uuid))")
                writeLine("\(styled("Flagged:", currentTheme.dim)) \(d.flagged)")
                writeLine("\(styled("Folder:", currentTheme.dim))  \(d.folder)")
                writeLine(styled("---", currentTheme.dim))
                writeLine(d.content ?? d.preview)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "action":
            guard let name = cmd.args.first else {
                writeLine(styled("Usage: /action <name> [--uuid <uuid>]", currentTheme.dim))
                break
            }
            do {
                let uuid = cmd.options["uuid"]
                let r = try DraftsBridge.runAction(name: name, uuid: uuid)
                writeLine(r)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "tag":
            guard cmd.args.count >= 2 else {
                writeLine(styled("Usage: /tag <uuid> <tag> ...", currentTheme.dim))
                break
            }
            do {
                let uuid = cmd.args[0]
                let tags = Array(cmd.args.dropFirst())
                let r = try DraftsBridge.setTags(uuid: uuid, tags: tags)
                writeLine(r)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "flag":
            guard let uuid = cmd.args.first else {
                writeLine(styled("Usage: /flag <uuid> [--unflag]", currentTheme.dim))
                break
            }
            do {
                let unflag = cmd.flags.contains("unflag")
                let r = try DraftsBridge.setFlag(uuid: uuid, flagged: !unflag)
                writeLine(r)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "folder":
            guard cmd.args.count >= 2 else {
                writeLine(styled("Usage: /folder <uuid> <inbox|archive|trash>", currentTheme.dim))
                break
            }
            do {
                let r = try DraftsBridge.setFolder(uuid: cmd.args[0], folder: cmd.args[1])
                writeLine(r)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "theme":
            if let arg = cmd.args.first?.lowercased() {
                switch arg {
                case "dark":
                    currentTheme = .dark
                    writeLine(styled("Theme set to dark", currentTheme.success))
                case "light":
                    currentTheme = .light
                    writeLine(styled("Theme set to light", currentTheme.success))
                default:
                    writeLine(styled("Usage: /theme <dark|light>", currentTheme.dim))
                }
            } else {
                writeLine("Current theme: \(currentTheme.name)")
            }

        default:
                writeLine("\(styled("Unknown command:", currentTheme.error)) /\(cmd.name). Type /help")
        }
    }
}

// MARK: - Interactive Command

struct InteractiveREPL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interactive",
        abstract: "Launch interactive REPL mode (default)"
    )

    func run() throws {
        try runREPL()
    }
}
