import Foundation

enum DraftsError: Error, CustomStringConvertible {
    case notInstalled
    case notAuthorized
    case appleScriptError(String)
    case emptyResult(String)

    var description: String {
        switch self {
        case .notInstalled:
            return "Drafts app is not installed on this Mac"
        case .notAuthorized:
            return """
            macOS permission required.
            Go to: System Settings > Privacy & Security > Automation
            Add/Terminal > Drafts, then try again.
            """
        case .appleScriptError(let msg):
            return "AppleScript error: \(msg)"
        case .emptyResult(let msg):
            return msg
        }
    }
}

struct Draft: CustomStringConvertible {
    let uuid: String
    let flagged: Bool
    let folder: String
    let preview: String
    let content: String?

    var description: String {
        let flag = flagged ? styled("★", currentTheme.accent) : styled("·", currentTheme.dim)
        let folderStyled = styled(folder.padding(toLength: 8, withPad: " ", startingAt: 0), currentTheme.dim)
        let uuidStyled = styled(String(uuid.prefix(8)), currentTheme.uuid)
        return "\(flag) \(folderStyled) \(uuidStyled)  \(preview)"
    }
}

struct DraftsBridge {
    @discardableResult private static func exec(script: String) throws -> String {
        let fm = FileManager.default
        let tempURL = fm.temporaryDirectory.appendingPathComponent("draftscript_\(UUID().uuidString).applescript")
        try script.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tempURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [tempURL.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
            if msg.contains("not authorized") || msg.contains("-1743") {
                throw DraftsError.notAuthorized
            }
            if msg.contains("where it’s not allowed") || msg.contains("application isn’t running") {
                throw DraftsError.notInstalled
            }
            throw DraftsError.appleScriptError(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Operations

    static func createViaURL(content: String, tags: String?, folder: String?, flagged: Bool) -> String? {
        var components = URLComponents()
        components.scheme = "drafts"
        components.host = "x-callback-url"
        components.path = "/create"
        var query: [URLQueryItem] = [.init(name: "text", value: content)]
        if let t = tags { query.append(.init(name: "tag", value: t)) }
        if let f = folder { query.append(.init(name: "folder", value: f)) }
        if flagged { query.append(.init(name: "flagged", value: "true")) }
        components.queryItems = query
        guard let url = components.url else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url.absoluteString]
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? "(created via URL scheme)" : nil
    }

    @discardableResult
    static func createDraft(content: String, tags: String?, folder: String?, flagged: Bool) throws -> String {
        var s = """
        tell application "Drafts"
            set newDraft to make new draft with properties {content:"\(esc(content))"
        """
        if flagged { s += ", flagged:true" }
        if let f = folder, !f.isEmpty { s += ", folder:\(f)" }
        s += "}\n"

        if let t = tags, !t.isEmpty {
            let tagItems = t.split(separator: ",").map { "\"\(esc($0.trimmingCharacters(in: .whitespaces)))\"" }.joined(separator: ", ")
            s += "set tag list of newDraft to {\(tagItems)}\n"
        }

        s += "return id of newDraft\nend tell"
        return try exec(script: s)
    }

    static func listDrafts(tag: String?, folder: String?, flagged: Bool?, search: String?, limit: Int = 50) throws -> [Draft] {
        var filterClauses: [String] = []
        if let f = folder { filterClauses.append("folder is equal to \(f)") }
        if let f = flagged { filterClauses.append("flagged is equal to \(f)") }
        if let s = search { filterClauses.append("content contains \"\(esc(s))\"") }
        let whereClause = filterClauses.isEmpty ? "" : " whose \(filterClauses.joined(separator: " and "))"

        let script = """
        on firstChars(txt, n)
            if length of txt > n then
                return text 1 thru n of txt
            else
                return txt
            end if
        end firstChars

        on cleanLine(txt)
            set AppleScript's text item delimiters to {return, linefeed, character id 10}
            set parts to text items of txt
            set AppleScript's text item delimiters to " "
            set result to parts as text
            set AppleScript's text item delimiters to ""
            return result
        end cleanLine

        tell application "Drafts"
            set myDrafts to every draft\(whereClause)
            set out to ""
            set counter to 0
            repeat with d in myDrafts
                if counter ≥ \(limit) then exit repeat
                set draftUUID to id of d
                set draftFlagged to flagged of d as text
                set draftFolder to folder of d as text
                set rawContent to content of d
                set preview to my cleanLine(my firstChars(rawContent, 80))
                set out to out & draftUUID & "\\t" & draftFlagged & "\\t" & draftFolder & "\\t" & preview & "\\n"
                set counter to counter + 1
            end repeat
            return out
        end tell
        """

        let result = try exec(script: script)
        guard !result.isEmpty else { return [] }

        return result.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            return Draft(
                uuid: parts[0],
                flagged: parts[1] == "true",
                folder: parts[2],
                preview: parts.count > 3 ? parts[3] : "",
                content: nil
            )
        }
    }

    static func listRecentDrafts(limit: Int = 10) throws -> [Draft] {
        let script = """
        on firstChars(txt, n)
            if length of txt > n then
                return text 1 thru n of txt
            else
                return txt
            end if
        end firstChars

        set epoch to current date
        set year of epoch to 1970
        set month of epoch to January
        set day of epoch to 1
        set time of epoch to 0

        tell application "Drafts"
            set myDrafts to every draft
            set out to ""
            repeat with d in myDrafts
                set draftUUID to id of d
                set draftFlagged to flagged of d as text
                set draftFolder to folder of d as text
                set modifiedSeconds to (modification date of d) - epoch
                set preview to my firstChars(title of d, 120)
                set out to out & draftUUID & "\\t" & draftFlagged & "\\t" & draftFolder & "\\t" & modifiedSeconds & "\\t" & preview & "\\n"
            end repeat
            return out
        end tell
        """

        let result = try exec(script: script)
        guard !result.isEmpty else { return [] }

        return result.split(separator: "\n")
            .compactMap { line -> (draft: Draft, modifiedSeconds: Double)? in
                let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { return nil }
                return (
                    draft: Draft(
                        uuid: parts[0],
                        flagged: parts[1] == "true",
                        folder: parts[2],
                        preview: parts.count > 4 ? parts[4] : "",
                        content: nil
                    ),
                    modifiedSeconds: Double(parts[3]) ?? 0
                )
            }
            .sorted { lhs, rhs in lhs.modifiedSeconds > rhs.modifiedSeconds }
            .prefix(limit)
            .map(\.draft)
    }

    static func getDraft(uuid: String) throws -> Draft {
        let script = """
        tell application "Drafts"
            set d to draft id "\(esc(uuid))"
            return id of d & "\\t" & (flagged of d as text) & "\\t" & (folder of d as text) & "\\t" & (content of d)
        end tell
        """

        let result = try exec(script: script)
        let parts = result.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { throw DraftsError.emptyResult("Draft not found: \(uuid)") }
        return Draft(
            uuid: parts[0],
            flagged: parts[1] == "true",
            folder: parts[2],
            preview: parts.count > 3 ? String(parts[3].prefix(80)) : "",
            content: parts.count > 3 ? parts[3] : nil
        )
    }

    @discardableResult
    static func updateDraft(uuid: String, content: String) throws -> String {
        let script = """
        tell application "Drafts"
            set d to draft id "\(esc(uuid))"
            set content of d to "\(esc(content))"
            return id of d
        end tell
        """

        return try exec(script: script)
    }

    static func getCurrentDraft() throws -> Draft {
        let script = """
        tell application "Drafts"
            set d to current draft
            if d is missing value then
                return ""
            end if
            return id of d & "\\t" & (flagged of d as text) & "\\t" & (folder of d as text) & "\\t" & (content of d)
        end tell
        """

        let result = try exec(script: script)
        guard !result.isEmpty else { throw DraftsError.emptyResult("No current draft") }
        let parts = result.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { throw DraftsError.emptyResult("No current draft") }
        return Draft(
            uuid: parts[0],
            flagged: parts[1] == "true",
            folder: parts[2],
            preview: parts.count > 3 ? String(parts[3].prefix(80)) : "",
            content: parts.count > 3 ? parts[3] : nil
        )
    }

    static func runAction(name: String, uuid: String?) throws -> String {
        let escapedName = esc(name)
        let script: String
        if let uuid = uuid {
            script = """
            tell application "Drafts"
                set myAction to action "\(escapedName)"
                set myDraft to draft id "\(esc(uuid))"
                perform action myAction on draft myDraft
                return "OK"
            end tell
            """
        } else {
            script = """
            tell application "Drafts"
                set myAction to action "\(escapedName)"
                set myDraft to current draft
                perform action myAction on draft myDraft
                return "OK"
            end tell
            """
        }
        try exec(script: script)
        return "Action \"\(name)\" ran" + (uuid.map { " on \($0)" } ?? " on current draft")
    }

    static func setTags(uuid: String, tags: [String]) throws -> String {
        let tagItems = tags.map { "\"\(esc($0))\"" }.joined(separator: ", ")
        let script = """
        tell application "Drafts"
            set d to draft id "\(esc(uuid))"
            set tag list of d to {\(tagItems)}
            return "Tags updated"
        end tell
        """
        return try exec(script: script)
    }

    static func setFlag(uuid: String, flagged: Bool) throws -> String {
        let val = flagged ? "true" : "false"
        let script = """
        tell application "Drafts"
            set d to draft id "\(esc(uuid))"
            set flagged of d to \(val)
            return "Flagged: \(val)"
        end tell
        """
        return try exec(script: script)
    }

    static func setFolder(uuid: String, folder: String) throws -> String {
        let script = """
        tell application "Drafts"
            set d to draft id "\(esc(uuid))"
            set folder of d to \(folder)
            return "Moved to \(folder)"
        end tell
        """
        return try exec(script: script)
    }

    static func fetchAllDrafts(limit: Int = 50) throws -> [(uuid: String, content: String)] {
        let script = """
        tell application "Drafts"
            set myDrafts to every draft
            set out to ""
            set counter to 0
            repeat with d in myDrafts
                if counter ≥ \(limit) then exit repeat
                set out to out & id of d & "\\t" & (content of d) & "\\n---DRAFTSEP---\\n"
                set counter to counter + 1
            end repeat
            return out
        end tell
        """

        let result = try exec(script: script)
        guard !result.isEmpty else { return [] }

        return result.components(separatedBy: "\n---DRAFTSEP---\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap { block -> (uuid: String, content: String)? in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let tabRange = trimmed.firstIndex(of: "\t") else { return nil }
                let uuid = String(trimmed[..<tabRange])
                let content = String(trimmed[trimmed.index(after: tabRange)...])
                return (uuid, content)
            }
    }
}
