# Agent Notes — DraftScript

## Overview

DraftScript is a Swift CLI tool that interfaces with the [Drafts](https://getdrafts.com) macOS app via AppleScript. It has two modes:

1. **Interactive REPL** (default) — `draftscript` enters a terminal UI with prompt, tab completion, history, navigable lists, multi-line compose mode, `/edit` draft editing, `/recent` draft browsing, and `/todo` pinned todo-list editing
2. **One-shot CLI** — `draftscript create "foo"`, `draftscript list`, etc. for scripting

Current build version: **1.2.0**. Latest GitHub release: **1.1.2** (`v1.1.2`, commit `5ac4dce`). Release asset is the macOS `draftscript` binary built from `.build/release/draftscript`.

## File Structure

```
Sources/draftscript/
├── CLI.swift              # @main entry, ArgumentParser config, default subcommand
├── Commands.swift         # One-shot subcommands (Create, List, Get, etc.)
├── DraftsBridge.swift     # AppleScript execution layer, Draft struct, CRUD helpers
├── LLMService.swift       # Ollama API client for semantic search
└── Interactive.swift      # Interactive REPL: terminal raw mode, line editor, navigator, compose/edit

Other:
├── Package.swift          # SwiftPM manifest, depends on swift-argument-parser
├── .gitignore             # Blocks build/, secrets, notes, .txt, etc.
├── README.md              # Full documentation
└── AGENTS.md              # This file
```

## Interactive.swift Architecture

### Components

**Terminal raw mode** (`enableRawMode` / `disableRawMode`):
- Uses termios (Darwin) to disable echo, canonical mode, signal keys
- Keeps `c_oflag` with OPOST off (no output processing — handles `\r\n` manually)
- Uses `writeStr()` / `writeLine()` helpers with explicit `\r\n`
- Signal handlers for SIGTERM/SIGINT via `sigaction` restore terminal state
- IMPORTANT: `\033` is NOT valid in Swift strings — use `\u{1B}` for ESC character

**Key reading** (`readKey()`):
- Returns `Key` enum: `.char(c)`, `.up`, `.down`, `.left`, `.right`, `.enter`, `.backspace`, `.tab`, `.ctrlC`, `.ctrlD`, `.escape`, `.delete`
- After receiving ESC (0x1B), polls with `poll()` + 15ms timeout to collect escape sequences
- Arrow keys: `ESC [ A` (up), `ESC [ B` (down), etc.

**Line editor** (`LineEditor` struct):
- Single-line input with prompt (`> `)
- Character insertion via `.char(c)` keys
- Backspace support
- History: arrow up/down cycles through previously submitted lines
- Tab completion: matches against `/new`, `/edit`, `/recent`, `/todo`, `/list`, `/search`, `/aisearch`, `/get`, `/current`, `/action`, `/tag`, `/flag`, `/folder`, `/model`, `/theme`, `/help`, `/exit`
- Ctrl+C/D returns `/exit` to quit REPL
- Uses `\r\u{1B}[K` (carriage return + clear line) to redraw prompt on each keystroke

**Command parser** (`parseCommand()` / `ParsedCmd`):
- Splits line respecting double-quoted strings
- Detects `/command`, parses `--flag` and `--option value` and positional args
- Returns `ParsedCmd(name, args, options, flags)`

**Compose mode** (`runCompose()`):
- Multi-line input for `/new` command
- Reads characters, echoes them, handles backspace
- Enter submits current line, `/end` on blank line saves, `/cancel` aborts
- Accumulates lines into content, calls `DraftsBridge.createDraft()` on save
- Options from `/new --tags work --flag` are forwarded to create

**Edit mode** (`/edit`, `navigateEditList()`, `runEdit()`):
- `/edit` calls `DraftsBridge.listRecentDrafts(limit: 10)` and shows an arrow-key selector with full UUID plus the draft title/first line
- The selector uses `drafts of current workspace`, not `every draft`, and exits after exactly `limit` drafts; this avoids the previous hang caused by scanning all drafts and computing `modification date` for every item
- Enter fetches full content with `DraftsBridge.getDraft(uuid:)`, opens `runEdit()`, and lets the user edit in a simple multiline buffer
- In edit mode, arrow keys move the cursor, Enter inserts lines, Backspace/Delete edit text, `/end` on its own line overwrites the existing draft via `DraftsBridge.updateDraft(uuid:content:)`
- `/cancel`, Escape, Ctrl-C, or Ctrl-D abort editing and return to the REPL without saving

**Recent mode** (`/recent`):
- `/recent` calls `DraftsBridge.listRecentDrafts(limit:)` with a default limit of 10 and shows a browsable list of recent current-workspace drafts
- Enter fetches full content with `DraftsBridge.getDraft(uuid:)` and opens the read-only viewer
- Pressing `/` while viewing a draft opened from `/recent` opens that draft in `runEdit()`
- `/recent --edit` reuses `navigateEditList()` so selecting a draft opens the same editor flow as `/edit`
- `/recent --limit <n>` adjusts the bounded query count; invalid limits fall back to 10

**Todo mode** (`/todo`, `runTodo()`):
- Opens a pinned Drafts draft as a line-by-line todo list; default ID/prefix is `399FDE34`
- Current todo draft selection is persisted in `~/.draftscript_todo_uuid`
- `/todo --change <uuid>` validates the new Drafts ID/prefix, resolves it to the full UUID when possible, and saves it for future sessions
- `/todo --change` with no value prompts for the new UUID in raw mode
- Up/down moves selection, Space/left/right toggles Markdown checkbox state, Enter edits the selected line, and edits/toggles save immediately via `DraftsBridge.updateDraft(uuid:content:)`

**List navigator** (`navigateList()`):
- Shows items with `→` cursor for selected item
- Arrow up/down to move selection, auto-scrolling when cursor moves past visible window
- Tracks `prevCount` of lines rendered for proper re-rendering (moves cursor up, clears, rewrites)
- Enter: calls `DraftsBridge.getDraft(uuid:)` to fetch full content, opens viewer
- Escape/q: returns to prompt

**View mode** (`viewContent()`):
- Shows full draft content with scroll offset
- Uses full-screen redraws so returning from one draft and opening another starts from a clean terminal state
- Arrow up/down to scroll, Escape to go back
- When opened from `/recent`, `/` enters edit mode for the viewed draft
- Truncates lines to terminal width

**REPL loop** (`runREPL()`):
- Enables raw mode on entry, disables on exit (defer)
- Creates `LineEditor`, loops reading lines
- Dispatches parsed commands to DraftsBridge/LLMService methods
- Dispatches interactive slash commands including `/new`, `/edit`, `/recent`, `/todo`, `/list`, `/search`, `/aisearch`, `/get`, `/current`, `/action`, `/tag`, `/flag`, `/folder`, `/model`, `/theme`, `/help`, `/exit`

### Key Design Decisions

1. **No external dependencies** — uses only Darwin/Foundation APIs. No SwiftTUI, no Linenoise wrapper. Keeps build simple.
2. **Default subcommand** — `InteractiveREPL` is the default via `CommandConfiguration.defaultSubcommand`. One-shot commands still work.
3. **Output in raw mode** — with `OPOST` off, all output uses `\r\n` manually via `writeStr`/`writeLine`.
4. **Content on demand** — list/edit navigators fetch full draft content via `getDraft(uuid:)` only when Enter is pressed, not in advance.
5. **Recent draft listing** — `/edit` and `/recent` intentionally use `drafts of current workspace` with a bounded limit. Do not reintroduce an `every draft` modification-date scan unless it is proven fast on large Drafts libraries.

## Known Limitations

- **ASCII-only input** — `readKey()` only handles single-byte characters (< 128). Multi-byte UTF-8 characters (emojis, accented chars) are not handled.
- **No word wrapping** — long lines are hard-truncated to terminal width in viewer and list.
- **No mouse support** — navigation is keyboard-only.
- **No resize handling** — terminal size is fetched once. If the terminal is resized while in list/view mode, the display may be off.
- **History not persisted** — command history is lost when the REPL exits.
- **No search/aisearch result count** — the LLM response mentions relevance but the list shows all drafts, not just the relevant ones.
- **Simple edit buffer** — `/edit` is an in-terminal line editor, not a full-screen editor with wrapping, selection, undo, or UTF-8-aware cursor movement.
- **Recent edit source** — `/edit` follows the current Drafts workspace ordering for the 10 displayed drafts; if global recency independent of workspace is required, investigate a Drafts-supported sorted query before scanning all drafts.

## Potential Improvements

1. **UTF-8 support** — accumulate raw bytes and decode as UTF-8 sequence for full Unicode input
2. **Search narrowing** — after `aisearch`, only show LLM-selected drafts in the list (not the full set)
3. **History persistence** — save/load `~/.draftscript_history`
4. **Resize handling** — catch `SIGWINCH` signal and update terminal dimensions
5. **Inline help** — `/help <command>` for per-command help
6. **Tab complete uuids** — complete recently seen draft UUIDs
7. **Add `/delete`** — with double-confirmation as user requested (Drafts uses soft-delete via trash folder anyway)
8. **`aisearch` streaming** — show LLM response token-by-token instead of all at once
9. **Status bar** — show current mode/draft count at bottom of screen
10. **External editor option** — optional `$EDITOR`/temporary-file based editing for richer draft editing than the built-in terminal buffer
11. **Global recent query** — if Drafts exposes a fast sorted query in a future API, use it for `/edit` instead of current workspace ordering

## Build

```bash
swift build -c release                    # Release build
cp .build/release/draftscript ~/.local/bin/  # Install
```

Release workflow example for `v1.2.0`:

```bash
swift build && swift build -c release
cp .build/release/draftscript ~/.local/bin/draftscript
gh release create v1.2.0 --target main --title "DraftScript 1.2.0" --notes "..." ".build/release/draftscript#draftscript-macos"
```

Verify installed version with:

```bash
~/.local/bin/draftscript --version
```

## Testing

No test suite exists yet. The tool interacts with the Drafts AppleScript API which requires the Drafts app to be installed. Testing would need mocking of the AppleScript layer or integration tests with the actual app.

Manual verification performed for the latest release:
- `swift build`
- `swift build -c release`
- `~/.local/bin/draftscript --version` returns `1.2.0`
- Direct `osascript` check of `drafts of current workspace` with `counter ≥ 10` returns 10 draft rows promptly
