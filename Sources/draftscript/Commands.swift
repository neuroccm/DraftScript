import ArgumentParser
import Foundation

// MARK: - Create

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new draft")

    @Argument(help: "Draft content (omit to pipe from stdin)")
    var text: String?

    @Option(help: "Comma-separated tags")
    var tags: String?

    @Option(help: "Folder: inbox, archive, or trash")
    var folder: String?

    @Flag(help: "Flag the draft")
    var flag: Bool = false

    func run() throws {
        let content: String
        if let t = text {
            content = t
        } else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !s.isEmpty else {
                print("\(styled("Error:", currentTheme.error)) provide text as argument or pipe it in")
                throw ExitCode.failure
            }
            content = s
        }

        do {
            let uuid = try DraftsBridge.createDraft(content: content, tags: tags, folder: folder, flagged: flag)
            print("\(styled("Created:", currentTheme.success)) \(styled(uuid, currentTheme.uuid))")
        } catch DraftsError.notAuthorized {
            print(styled("Note:", currentTheme.accent) + " Grant Terminal access to Drafts in System Settings > Privacy & Security > Automation")
            print(styled("Falling back to URL scheme (no UUID returned)...", currentTheme.dim))
            if let result = DraftsBridge.createViaURL(content: content, tags: tags, folder: folder, flagged: flag) {
                print("\(styled("Created", currentTheme.success)) \(result)")
            } else {
                print(styled("Failed to create via URL scheme", currentTheme.error))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - List

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List drafts")

    @Option(help: "Filter by tag")
    var tag: String?

    @Option(help: "Filter by folder (inbox, archive, trash)")
    var folder: String?

    @Flag(help: "Show only flagged drafts")
    var flagged: Bool = false

    @Option(help: "Search text in content")
    var search: String?

    @Option(help: "Maximum results (default: 50)")
    var limit: Int = 50

    func run() throws {
        let drafts = try DraftsBridge.listDrafts(tag: tag, folder: folder, flagged: flagged ? true : nil, search: search, limit: limit)
        guard !drafts.isEmpty else {
            print(styled("No drafts found", currentTheme.dim))
            return
        }
        for d in drafts {
            print(d)
        }
        print(styled("---\n\(drafts.count) draft(s)", currentTheme.dim))
    }
}

// MARK: - Get

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get a draft by UUID")

    @Argument(help: "UUID of the draft")
    var uuid: String

    func run() throws {
        let draft = try DraftsBridge.getDraft(uuid: uuid)
        print("\(styled("UUID:", currentTheme.dim))   \(styled(draft.uuid, currentTheme.uuid))")
        print("\(styled("Flagged:", currentTheme.dim)) \(draft.flagged)")
        print("\(styled("Folder:", currentTheme.dim))  \(draft.folder)")
        print(styled("---", currentTheme.dim))
        print(draft.content ?? draft.preview)
    }
}

// MARK: - Current

struct Current: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the current draft in the editor")

    func run() throws {
        let draft = try DraftsBridge.getCurrentDraft()
        print("\(styled("UUID:", currentTheme.dim))   \(styled(draft.uuid, currentTheme.uuid))")
        print("\(styled("Flagged:", currentTheme.dim)) \(draft.flagged)")
        print("\(styled("Folder:", currentTheme.dim))  \(draft.folder)")
        print(styled("---", currentTheme.dim))
        print(draft.content ?? draft.preview)
    }
}

// MARK: - TextSearch

struct TextSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search drafts by text content"
    )

    @Argument(help: "Search query")
    var query: String

    @Option(help: "Filter by folder")
    var folder: String?

    @Option(help: "Maximum results (default: 50)")
    var limit: Int = 50

    func run() throws {
        let drafts = try DraftsBridge.listDrafts(tag: nil, folder: folder, flagged: nil, search: query, limit: limit)
        guard !drafts.isEmpty else {
            print(styled("No drafts matching \"\(query)\"", currentTheme.dim))
            return
        }
        for d in drafts {
            print(d)
        }
        print(styled("---\n\(drafts.count) match(es)", currentTheme.dim))
    }
}

// MARK: - AISearch

struct AISearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aisearch",
        abstract: "Search drafts using a local LLM (Ollama)"
    )

    @Argument(help: "Search query for AI-powered semantic search")
    var query: String

    @Flag(help: "Show all drafts sent to the model")
    var verbose: Bool = false

    @Option(help: "Number of drafts to consider (default: 50)")
    var limit: Int = 50

    func run() throws {
        print(styled("Fetching drafts...", currentTheme.accent), terminator: " ")
        let drafts = try DraftsBridge.fetchAllDrafts(limit: limit)
        print(styled("\(drafts.count) found", currentTheme.dim))

        guard !drafts.isEmpty else {
            print(styled("No drafts to search", currentTheme.dim))
            return
        }

        guard LLMService.isAvailable else {
            print(styled("""
            Ollama is not available.
            Install it from https://ollama.com then pull a model:
              ollama pull gemma4
            """, currentTheme.error))
            throw ExitCode.failure
        }

        if verbose {
            print(styled("\nAll drafts:", currentTheme.header))
            for (i, d) in drafts.enumerated() {
                let preview = d.content.prefix(100).replacingOccurrences(of: "\n", with: " ")
                print("  [\(i + 1)] \(styled(String(d.uuid.prefix(8)), currentTheme.uuid))  \(preview)")
            }
            print()
        }

        print(styled("Querying LLM (\(LLMService.model))...", currentTheme.accent))
        let response = try LLMService.searchDrafts(query: query, drafts: drafts)
        print()
        print(response)
    }
}

// MARK: - RunAction

struct RunAction: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "action",
        abstract: "Run a Drafts action on a draft"
    )

    @Argument(help: "Name of the action to run")
    var name: String

    @Option(help: "UUID of the draft (defaults to current draft)")
    var uuid: String?

    func run() throws {
        let result = try DraftsBridge.runAction(name: name, uuid: uuid)
        print(result)
    }
}

// MARK: - SetTag

struct SetTag: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Set tags on a draft"
    )

    @Argument(help: "UUID of the draft")
    var uuid: String

    @Argument(parsing: .remaining, help: "Tags to set")
    var tags: [String]

    func run() throws {
        guard !tags.isEmpty else {
            print("\(styled("Error:", currentTheme.error)) provide at least one tag")
            throw ExitCode.failure
        }
        let result = try DraftsBridge.setTags(uuid: uuid, tags: tags)
        print(result)
    }
}

// MARK: - FlagDraft

struct FlagDraft: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flag",
        abstract: "Toggle flag on a draft"
    )

    @Argument(help: "UUID of the draft")
    var uuid: String

    @Flag(help: "Unflag instead of flag")
    var unflag: Bool = false

    func run() throws {
        let result = try DraftsBridge.setFlag(uuid: uuid, flagged: !unflag)
        print(result)
    }
}

// MARK: - Folder

struct Folder: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move a draft to a folder")

    @Argument(help: "UUID of the draft")
    var uuid: String

    @Argument(help: "Folder: inbox, archive, or trash")
    var folder: String

    func run() throws {
        let result = try DraftsBridge.setFolder(uuid: uuid, folder: folder)
        print(result)
    }
}
