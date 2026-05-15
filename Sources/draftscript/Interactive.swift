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

var ollamaUp: Bool = false
let defaultTodoDraftUUID = "399FDE34"
let todoDraftConfigFile = ".draftscript_todo_uuid"

func todoDraftConfigURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(todoDraftConfigFile)
}

func currentTodoDraftUUID() -> String {
    let url = todoDraftConfigURL()
    guard let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return defaultTodoDraftUUID }
    return value
}

func saveTodoDraftUUID(_ uuid: String) throws {
    try (uuid + "\n").write(to: todoDraftConfigURL(), atomically: true, encoding: .utf8)
}

func promptText() -> String {
    let dot = ollamaUp ? "\u{25CF}" : "\u{25CB}"
    let dotStyle = Style(fg: ollamaUp ? 32 : 31)
    return "\(styled(dot, dotStyle)) \(styled("> ", currentTheme.prompt))"
}

struct AISearchTerm {
    let text: String
    let variants: [String]
}

func commandQuery(_ cmd: ParsedCmd) -> String? {
    if !cmd.args.isEmpty { return cmd.args.joined(separator: " ") }
    return cmd.options["query"]
}

func aiSearchTerms(from query: String) -> [AISearchTerm] {
    let lowerQuery = query.lowercased()
    let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "based", "be", "been", "between", "by", "can",
        "compare", "compared", "did", "do", "does", "for", "from", "had", "has", "have", "heavier",
        "heavy", "how", "i", "in", "is", "it", "lighter", "light", "me", "my", "of", "on", "or",
        "than", "that", "the", "them", "then", "there", "these", "this", "to", "using", "was", "were",
        "what", "when", "where", "which", "who", "why", "with"
    ]

    var rawTerms = lowerQuery
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { $0.count >= 3 && !stopwords.contains($0) }

    if lowerQuery.contains("heavier") || lowerQuery.contains("lighter") || lowerQuery.contains("weight") || lowerQuery.contains("weigh") {
        rawTerms.append("weight")
    }

    var seen = Set<String>()
    return rawTerms.compactMap { term in
        guard seen.insert(term).inserted else { return nil }
        var variants = [term]
        if term == "thunderburt" {
            variants.append(contentsOf: ["thunder burt", "thunder", "burt"])
        } else if term == "weight" {
            variants.append(contentsOf: ["weigh", "grams"])
        }
        return AISearchTerm(text: term, variants: Array(NSOrderedSet(array: variants)) as? [String] ?? variants)
    }
}

func aiSearchScore(content: String, terms: [AISearchTerm]) -> Int {
    let lower = content.lowercased()
    var score = 0
    var matchedGroups = 0

    for term in terms {
        var groupMatches = 0
        for variant in term.variants {
            let needle = variant.lowercased()
            guard !needle.isEmpty else { continue }
            groupMatches += lower.components(separatedBy: needle).count - 1
        }
        if groupMatches > 0 {
            matchedGroups += 1
            score += 10 + groupMatches
        }
    }

    return score + (matchedGroups * 25)
}

func fetchAISearchDrafts(query: String, limit: Int) throws -> (drafts: [(uuid: String, content: String)], terms: [AISearchTerm], fallback: Bool) {
    let terms = aiSearchTerms(from: query)
    let candidateLimit = max(1, min(limit, 8))
    var orderedIDs: [String] = []
    var seenIDs = Set<String>()

    for term in terms {
        for variant in term.variants {
            let matches = try DraftsBridge.listDrafts(tag: nil, folder: nil, flagged: nil, search: variant, limit: candidateLimit)
            for match in matches where seenIDs.insert(match.uuid).inserted {
                orderedIDs.append(match.uuid)
            }
        }
    }

    var drafts: [(uuid: String, content: String)] = []
    for uuid in orderedIDs.prefix(candidateLimit) {
        if let full = try? DraftsBridge.getDraft(uuid: uuid),
           let content = full.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.append((uuid: full.uuid, content: content))
        }
    }

    if drafts.isEmpty {
        drafts = try DraftsBridge.fetchAllDrafts(limit: candidateLimit)
        return (drafts, terms, true)
    }

    let ranked = drafts
        .map { draft in (draft: draft, score: aiSearchScore(content: draft.content, terms: terms)) }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.draft.uuid < rhs.draft.uuid : lhs.score > rhs.score }

    let filtered = ranked.filter { $0.score > 0 }.map(\.draft)
    return (Array((filtered.isEmpty ? drafts : filtered).prefix(candidateLimit)), terms, false)
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
    let n = read(STDIN_FILENO, &byte, 1)
    guard n == 1 else { return n == 0 ? .ctrlD : .unknown }

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

    static let commands = [
        "new", "edit", "recent", "todo", "list", "search", "aisearch", "get",
        "current", "action", "tag", "flag", "folder",
        "model", "theme", "help", "exit"
    ]

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
        writeStr(promptText() + buffer)
        while true {
            let key = readKey()
            switch key {
            case .char(let c):
                addChar(c)
                clearLine()
                writeStr(promptText() + buffer)
            case .backspace:
                deleteChar()
                clearLine()
                writeStr(promptText() + buffer)
            case .up:
                historyPrev()
                clearLine()
                writeStr(promptText() + buffer)
            case .down:
                historyNext()
                clearLine()
                writeStr(promptText() + buffer)
            case .tab:
                tabComplete()
                clearLine()
                writeStr(promptText() + buffer)
                if tabCycle.count > 1 {
                    writeLine()
                    let suggestions = tabCycle.map { styled("/" + $0, currentTheme.accent) }.joined(separator: "  ")
                    writeStr("  " + suggestions)
                    clearLine()
                    writeStr(promptText() + buffer)
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

func runEdit(uuid: String, existingContent: String) {
    var lines = existingContent.components(separatedBy: "\n")
    if lines.isEmpty { lines = [""] }
    var row = lines.count - 1
    var col = lines[row].count
    var offset = 0

    func visibleLine(_ line: String, width: Int) -> String {
        let maxWidth = max(width - 1, 1)
        return line.count > maxWidth ? String(line.prefix(maxWidth)) : line
    }

    func render() {
        let (width, height) = terminalSize()
        let visible = max(height - 5, 3)
        if row < offset { offset = row }
        if row >= offset + visible { offset = row - visible + 1 }

        writeStr("\u{1B}[2J\u{1B}[H")
        writeLine(styled("── Editing \(uuid) (/end save, /cancel abort) ──", currentTheme.header))

        let end = min(offset + visible, lines.count)
        for i in offset..<end {
            let prefix = i == row ? styled("› ", currentTheme.cursor) : "  "
            writeLine(prefix + visibleLine(lines[i], width: width - 2))
        }

        for _ in 0..<max(0, visible - (end - offset)) {
            writeLine("~")
        }

        writeLine(styled("Arrows move. Enter inserts line. Type /end on its own line to save.", currentTheme.dim))

        let screenRow = 2 + (row - offset)
        let screenCol = min(col + 3, max(width, 1))
        writeStr("\u{1B}[\(screenRow);\(screenCol)H")
    }

    func save() {
        do {
            let content = lines.joined(separator: "\n")
            let savedUUID = try DraftsBridge.updateDraft(uuid: uuid, content: content)
            writeStr("\u{1B}[2J\u{1B}[H")
            writeLine("\(styled("Updated:", currentTheme.success)) \(styled(savedUUID, currentTheme.uuid))")
        } catch {
            writeStr("\u{1B}[2J\u{1B}[H")
            writeLine("\(styled("Error:", currentTheme.error)) \(error)")
        }
    }

    render()
    while true {
        let key = readKey()
        switch key {
        case .char(let c):
            lines[row].insert(c, at: lines[row].index(lines[row].startIndex, offsetBy: col))
            col += 1
            render()
        case .enter:
            let trimmed = lines[row].trimmingCharacters(in: .whitespaces)
            if trimmed == "/end" {
                lines.remove(at: row)
                if lines.isEmpty { lines = [""] }
                save()
                return
            }
            if trimmed == "/cancel" {
                writeStr("\u{1B}[2J\u{1B}[H")
                writeLine(styled("Cancelled.", currentTheme.dim))
                return
            }

            let line = lines[row]
            let splitIndex = line.index(line.startIndex, offsetBy: col)
            let before = String(line[..<splitIndex])
            let after = String(line[splitIndex...])
            lines[row] = before
            lines.insert(after, at: row + 1)
            row += 1
            col = 0
            render()
        case .backspace:
            if col > 0 {
                let removeIndex = lines[row].index(lines[row].startIndex, offsetBy: col - 1)
                lines[row].remove(at: removeIndex)
                col -= 1
            } else if row > 0 {
                let previousCount = lines[row - 1].count
                lines[row - 1] += lines[row]
                lines.remove(at: row)
                row -= 1
                col = previousCount
            }
            render()
        case .delete:
            if col < lines[row].count {
                let removeIndex = lines[row].index(lines[row].startIndex, offsetBy: col)
                lines[row].remove(at: removeIndex)
            } else if row + 1 < lines.count {
                lines[row] += lines[row + 1]
                lines.remove(at: row + 1)
            }
            render()
        case .left:
            if col > 0 {
                col -= 1
            } else if row > 0 {
                row -= 1
                col = lines[row].count
            }
            render()
        case .right:
            if col < lines[row].count {
                col += 1
            } else if row + 1 < lines.count {
                row += 1
                col = 0
            }
            render()
        case .up:
            guard row > 0 else { break }
            row -= 1
            col = min(col, lines[row].count)
            render()
        case .down:
            guard row + 1 < lines.count else { break }
            row += 1
            col = min(col, lines[row].count)
            render()
        case .ctrlC, .ctrlD, .escape:
            writeStr("\u{1B}[2J\u{1B}[H")
            writeLine(styled("Cancelled.", currentTheme.dim))
            return
        default:
            break
        }
    }
}

// MARK: - Todo mode

func todoCheckboxState(_ line: String) -> Bool? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed == "- [x]" || trimmed.hasPrefix("- [x] ") || trimmed == "- [X]" || trimmed.hasPrefix("- [X] ") {
        return true
    }
    if trimmed == "- [ ]" || trimmed.hasPrefix("- [ ] ") {
        return false
    }
    return nil
}

func todoLineBody(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard todoCheckboxState(trimmed) != nil else { return trimmed }
    var body = String(trimmed.dropFirst(5))
    if body.hasPrefix(" ") { body.removeFirst() }
    return body
}

func todoLeadingWhitespace(_ line: String) -> String {
    String(line.prefix { $0 == " " || $0 == "\t" })
}

func toggledTodoLine(_ line: String) -> String {
    let checked = todoCheckboxState(line) ?? false
    let body = todoLineBody(line)
    return "\(todoLeadingWhitespace(line))- [\(!checked ? "x" : " ")] \(body)"
}

func editTodoLine(_ initial: String) -> String? {
    var chars = Array(initial)
    var col = chars.count

    func render() {
        let (width, _) = terminalSize()
        let value = String(chars)
        let visible = value.count > max(width - 8, 1) ? String(value.prefix(max(width - 8, 1))) : value
        writeStr("\u{1B}[2J\u{1B}[H")
        writeLine(styled("── Edit todo line (Enter save, Esc cancel) ──", currentTheme.header))
        writeLine("Edit: \(visible)")
        writeLine(styled("Use ←/→, Backspace, Delete. Keep '- [ ]' or '- [x]' for checkbox state.", currentTheme.dim))
        let screenCol = min(7 + col, max(width, 1))
        writeStr("\u{1B}[2;\(screenCol)H")
    }

    render()
    while true {
        switch readKey() {
        case .char(let c):
            chars.insert(c, at: col)
            col += 1
            render()
        case .backspace:
            if col > 0 {
                chars.remove(at: col - 1)
                col -= 1
                render()
            }
        case .delete:
            if col < chars.count {
                chars.remove(at: col)
                render()
            }
        case .left:
            if col > 0 { col -= 1; render() }
        case .right:
            if col < chars.count { col += 1; render() }
        case .enter:
            return String(chars)
        case .escape, .ctrlC, .ctrlD:
            return nil
        default:
            break
        }
    }
}

func readTodoUUIDInput(current: String) -> String? {
    var buffer = ""
    let prompt = "New todo draft UUID (current \(current), Esc cancel): "

    func render() {
        clearLine()
        writeStr(prompt + buffer)
    }

    render()
    while true {
        switch readKey() {
        case .char(let c):
            buffer.append(c)
            render()
        case .backspace:
            if !buffer.isEmpty {
                buffer.removeLast()
                render()
            }
        case .enter:
            writeLine()
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        case .escape, .ctrlC, .ctrlD:
            writeLine()
            return nil
        default:
            break
        }
    }
}

func resolveTodoDraft(uuidOrPrefix: String) throws -> Draft {
    do {
        return try DraftsBridge.getDraft(uuid: uuidOrPrefix)
    } catch {
        if let fullUUID = try DraftsBridge.findDraftUUID(prefix: uuidOrPrefix) {
            return try DraftsBridge.getDraft(uuid: fullUUID)
        }
        throw error
    }
}

func changeTodoDraftUUID(to requestedUUID: String?) {
    let current = currentTodoDraftUUID()
    let uuid = requestedUUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? readTodoUUIDInput(current: current)
    guard let uuid, !uuid.isEmpty else {
        writeLine(styled("Todo draft unchanged.", currentTheme.dim))
        return
    }

    do {
        let draft = try resolveTodoDraft(uuidOrPrefix: uuid)
        try saveTodoDraftUUID(draft.uuid)
        writeLine("\(styled("Todo draft changed:", currentTheme.success)) \(styled(draft.uuid, currentTheme.uuid))")
        writeLine(styled("Saved in ~/\(todoDraftConfigFile)", currentTheme.dim))
    } catch {
        writeLine("\(styled("Error:", currentTheme.error)) Unable to use todo draft \(uuid): \(error)")
    }
}

func runTodo() {
    do {
        let todoDraftUUID = currentTodoDraftUUID()
        let draft = try resolveTodoDraft(uuidOrPrefix: todoDraftUUID)
        var lines = (draft.content ?? "").components(separatedBy: "\n")
        if lines.isEmpty { lines = [""] }
        var idx = 0
        var offset = 0
        var status = "Todo draft: \(draft.uuid)"

        func save() {
            do {
                _ = try DraftsBridge.updateDraft(uuid: draft.uuid, content: lines.joined(separator: "\n"))
                status = "Saved \(draft.uuid)"
            } catch {
                status = "Error saving: \(error)"
            }
        }

        func visibleLine(_ line: String, width: Int) -> String {
            let maxWidth = max(width - 4, 1)
            return line.count > maxWidth ? String(line.prefix(maxWidth)) : line
        }

        func render() {
            let (width, height) = terminalSize()
            let visible = max(height - 5, 3)
            if idx < offset { offset = idx }
            if idx >= offset + visible { offset = idx - visible + 1 }

            writeStr("\u{1B}[2J\u{1B}[H")
            writeLine(styled("── Todo (↑/↓ move, Space/←/→ toggle, Enter edit, q back) ──", currentTheme.header))

            let end = min(offset + visible, lines.count)
            for i in offset..<end {
                let cursor = i == idx ? styled("→ ", currentTheme.cursor) : "  "
                writeLine(cursor + visibleLine(lines[i], width: width - 2))
            }

            for _ in 0..<max(0, visible - (end - offset)) {
                writeLine("~")
            }

            let style = status.hasPrefix("Error") ? currentTheme.error : currentTheme.dim
            writeLine(styled(status, style))
        }

        render()
        while true {
            switch readKey() {
            case .up:
                if idx > 0 { idx -= 1; render() }
            case .down:
                if idx + 1 < lines.count { idx += 1; render() }
            case .char(" "), .left, .right:
                lines[idx] = toggledTodoLine(lines[idx])
                save()
                render()
            case .enter:
                if let edited = editTodoLine(lines[idx]) {
                    lines[idx] = edited
                    save()
                } else {
                    status = "Edit cancelled"
                }
                render()
            case .escape, .char("q"), .ctrlC, .ctrlD:
                writeStr("\u{1B}[2J\u{1B}[H")
                return
            default:
                break
            }
        }
    } catch {
        writeLine("\(styled("Error:", currentTheme.error)) Unable to open todo draft \(currentTodoDraftUUID()): \(error)")
        writeLine(styled("Use /todo --change <uuid> to choose a different todo draft.", currentTheme.dim))
    }
}

// MARK: - List navigator + view mode

func viewContent(_ content: String, label: String, canEdit: Bool = false) -> Bool {
    var offset = 0

    func render() {
        let (width, height) = terminalSize()
        let visibleHeight = max(height - 3, 1)
        let lines = content.components(separatedBy: "\n").map { line -> String in
            let maxWidth = max(width - 2, 1)
            return line.count > maxWidth ? String(line.prefix(maxWidth)) : line
        }
        let maxOffset = max(0, lines.count - visibleHeight)
        if offset > maxOffset { offset = maxOffset }
        let end = min(offset + visibleHeight, lines.count)
        let help = canEdit ? "\u{2191}/\u{2193} scroll, / edit, Esc back" : "\u{2191}/\u{2193} scroll, Esc back"

        writeStr("\u{1B}[2J\u{1B}[H")
        writeLine(styled("\u{2500}\u{2500} \(label) (\(help)) \u{2500}\u{2500}", currentTheme.header))
        for i in offset..<end {
            writeLine(" " + lines[i])
        }
        for _ in 0..<max(0, visibleHeight - (end - offset)) {
            writeLine("~")
        }
    }

    render()
    while true {
        let key = readKey()
        switch key {
        case .up where offset > 0:
            offset -= 1
            render()
        case .down:
            let (_, height) = terminalSize()
            let maxOffset = max(0, content.components(separatedBy: "\n").count - max(height - 3, 1))
            guard offset < maxOffset else { break }
            offset += 1
            render()
        case .char("/") where canEdit:
            return true
        case .escape, .char("q"):
            return false
        default:
            break
        }
    }
}

func navigateList(drafts: [(uuid: String, content: String)], label: String, allowInlineEdit: Bool = false) {
    var idx = 0
    var offset = 0

    func render() {
        let (width, height) = terminalSize()
        let visible = max(height - 4, 3)
        if idx < offset { offset = idx }
        if idx >= offset + visible { offset = idx - visible + 1 }
        let end = min(offset + visible, drafts.count)

        writeStr("\u{1B}[2J\u{1B}[H")
        writeLine(styled("\u{2500}\u{2500} \(label) (\u{2191}/\u{2193} select, Enter view, q back) \u{2500}\u{2500}", currentTheme.header))
        for i in offset..<end {
            let d = drafts[i]
            let previewWidth = max(width - 10, 1)
            let preview = d.content.prefix(previewWidth).replacingOccurrences(of: "\n", with: " ")
            let cursor = i == idx ? styled("\u{2192} ", currentTheme.cursor) : "  "
            let uuid = styled(String(d.uuid.prefix(8)), currentTheme.uuid)
            writeLine("\(cursor)\(uuid)  \(preview)")
        }
        for _ in 0..<max(0, visible - (end - offset)) {
            writeLine("~")
        }
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
            let (_, height) = terminalSize()
            let visible = max(height - 4, 3)
            if idx >= offset + visible { offset = idx - visible + 1 }
            render()
        case .enter:
            let d = drafts[idx]
            do {
                let full = try DraftsBridge.getDraft(uuid: d.uuid)
                let content = full.content ?? full.preview
                if viewContent(content, label: full.uuid, canEdit: allowInlineEdit) {
                    runEdit(uuid: full.uuid, existingContent: content)
                }
            } catch {
                _ = viewContent(d.content, label: d.uuid)
            }
            render()
        case .escape, .char("q"):
            return
        default:
            break
        }
    }
}

func navigateEditList(drafts: [Draft]) {
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
        writeLine(styled("── Edit recent drafts (↑/↓ select, Enter edit, q back) ──", currentTheme.header))
        for i in offset..<end {
            writeStr("\r\u{1B}[K")
            let d = drafts[i]
            let cursor = i == idx ? styled("→ ", currentTheme.cursor) : "  "
            let uuid = styled(d.uuid, currentTheme.uuid)
            let previewWidth = max(width - 42, 10)
            let preview = d.preview.count > previewWidth ? String(d.preview.prefix(previewWidth)) : d.preview
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
                runEdit(uuid: full.uuid, existingContent: full.content ?? full.preview)
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }
            return
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
    writeLine("  \(styled("/edit", a))                         Select one of the 10 most recently modified drafts and edit it")
    writeLine("  \(styled("/recent", a)) [--limit <n>] [--edit] Browse recent drafts, or edit with --edit")
    writeLine("  \(styled("/todo", a)) [--change <uuid>]        Open or change the pinned todo draft")
    writeLine("  \(styled("/list", a)) [--tag <t>] [--folder <f>] [--flagged] [--search <q>] [--limit <n>]")
    writeLine("  \(styled("/search", a)) <q> [--folder <f>] [--limit <n>]")
    writeLine("  \(styled("/aisearch", a)) <q> [--limit <n>]")
    writeLine("  \(styled("/get", a)) <uuid>")
    writeLine("  \(styled("/current", a))")
    writeLine("  \(styled("/action", a)) <name> [--uuid <uuid>]")
    writeLine("  \(styled("/tag", a)) <uuid> <tag> ...")
    writeLine("  \(styled("/flag", a)) <uuid> [--unflag]")
    writeLine("  \(styled("/folder", a)) <uuid> <inbox|archive|trash>")
    writeLine("  \(styled("/model", a)) <name>     Set Ollama model")
    writeLine("  \(styled("/help", a))  \(styled("/exit", a))")
}

func runREPL() throws {
    enableRawMode()
    defer { disableRawMode() }

    writeLine(styled("DraftScript interactive. Type /help for commands. /exit or ^C to quit.", currentTheme.header))

    writeStr("Checking Ollama... ")
    ollamaUp = LLMService.isAvailable
    if ollamaUp {
        writeLine("\(styled("\u{25CF} \(LLMService.model)", Style(fg: 32)))")
    } else {
        writeLine("\(styled("\u{25CB} offline", Style(fg: 31)))")
    }
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

        case "edit":
            do {
                let drafts = try DraftsBridge.listRecentDrafts(limit: 10)
                if drafts.isEmpty {
                    writeLine(styled("No drafts found.", currentTheme.dim))
                } else {
                    navigateEditList(drafts: drafts)
                }
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "recent":
            do {
                let parsedLimit = Int(cmd.options["limit"] ?? "")
                let limit = parsedLimit.map { $0 > 0 ? $0 : 10 } ?? 10
                let drafts = try DraftsBridge.listRecentDrafts(limit: limit)
                if drafts.isEmpty {
                    writeLine(styled("No drafts found.", currentTheme.dim))
                } else if cmd.flags.contains("edit") {
                    navigateEditList(drafts: drafts)
                } else {
                    let items: [(uuid: String, content: String)] = drafts.map { ($0.uuid, $0.content ?? $0.preview) }
                    navigateList(drafts: items, label: "Recent drafts", allowInlineEdit: true)
                }
            } catch {
                writeLine("\(styled("Error:", currentTheme.error)) \(error)")
            }

        case "todo":
            if let uuid = cmd.options["change"] ?? cmd.args.first, cmd.options["change"] != nil || cmd.flags.contains("change") {
                changeTodoDraftUUID(to: uuid)
            } else if cmd.flags.contains("change") {
                changeTodoDraftUUID(to: nil)
            } else {
                runTodo()
            }

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
            guard let query = commandQuery(cmd) else {
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
            guard let query = commandQuery(cmd) else {
                writeLine(styled("Usage: /aisearch <query> [--limit <n>]", currentTheme.dim))
                break
            }
            let limit = Int(cmd.options["limit"] ?? "") ?? 50
            guard LLMService.isAvailable else {
                writeLine(styled("Ollama is not available.", currentTheme.error) + "\r\nInstall from https://ollama.com then pull: ollama pull gemma4")
                break
            }

            writeStr(styled("Searching for \"\(query)\"... ", currentTheme.accent))
            do {
                let result = try fetchAISearchDrafts(query: query, limit: limit)
                let drafts = result.drafts
                guard !drafts.isEmpty else { writeLine(styled("No drafts to search.", currentTheme.dim)); break }

                if result.terms.isEmpty {
                    writeLine(styled("No search terms extracted. Using recent drafts.", currentTheme.dim))
                } else if result.fallback {
                    let terms = result.terms.map(\.text).joined(separator: ", ")
                    writeLine(styled("No direct text matches for: \(terms). Using recent drafts.", currentTheme.dim))
                } else {
                    let terms = result.terms.map(\.text).joined(separator: ", ")
                    writeLine(styled("\(drafts.count) matching drafts loaded for: \(terms).", currentTheme.dim))
                }

                writeLine(styled("Querying LLM (\(LLMService.model))...", currentTheme.accent))
                writeLine(styled("Synthesizing \(drafts.count) drafts...", currentTheme.dim))
                let response = try LLMService.searchDrafts(query: query, drafts: drafts)
                writeLine("")
                writeLine(response)
                writeLine("")
                writeLine(styled("Use /get <uuid> to view any draft above.", currentTheme.dim))
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

        case "model":
            if let arg = cmd.args.first {
                LLMService.model = arg
                writeLine("\(styled("Model set to", currentTheme.success)) \(styled(arg, currentTheme.accent))")
            } else {
                writeLine("Current model: \(styled(LLMService.model, currentTheme.accent))")
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
