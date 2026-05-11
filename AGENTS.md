# Agent Notes — DraftScript

## Overview

DraftScript is a Swift CLI tool that interfaces with the [Drafts](https://getdrafts.com) macOS app via AppleScript. It has two modes:

1. **Interactive REPL** (default) — `draftscript` enters a terminal UI with prompt, tab completion, history, navigable lists, and multi-line compose mode
2. **One-shot CLI** — `draftscript create "foo"`, `draftscript list`, etc. for scripting

## File Structure

```
Sources/draftscript/
├── CLI.swift              # @main entry, ArgumentParser config, default subcommand
├── Commands.swift         # 10 one-shot subcommands (Create, List, Get, etc.)
├── DraftsBridge.swift     # AppleScript execution layer, Draft struct, error types
├── LLMService.swift       # Ollama API client for semantic search
└── Interactive.swift      # Interactive REPL: terminal raw mode, line editor, navigator, compose

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
- Tab completion: matches against `/new`, `/list`, `/search`, `/aisearch`, `/get`, `/current`, `/action`, `/tag`, `/flag`, `/folder`, `/help`, `/exit`
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

**List navigator** (`navigateList()`):
- Shows items with `→` cursor for selected item
- Arrow up/down to move selection, auto-scrolling when cursor moves past visible window
- Tracks `prevCount` of lines rendered for proper re-rendering (moves cursor up, clears, rewrites)
- Enter: calls `DraftsBridge.getDraft(uuid:)` to fetch full content, opens viewer
- Escape/q: returns to prompt

**View mode** (`viewContent()`):
- Shows full draft content with scroll offset
- Arrow up/down to scroll, Escape to go back
- Truncates lines to terminal width

**REPL loop** (`runREPL()`):
- Enables raw mode on entry, disables on exit (defer)
- Creates `LineEditor`, loops reading lines
- Dispatches parsed commands to DraftsBridge/LLMService methods
- All 10 commands + help + exit

### Key Design Decisions

1. **No external dependencies** — uses only Darwin/Foundation APIs. No SwiftTUI, no Linenoise wrapper. Keeps build simple.
2. **Existing code unchanged** — `DraftsBridge.swift` and `LLMService.swift` required zero modifications. The REPL calls them directly.
3. **Default subcommand** — `InteractiveREPL` is the default via `CommandConfiguration.defaultSubcommand`. One-shot commands still work.
4. **Output in raw mode** — with `OPOST` off, all output uses `\r\n` manually via `writeStr`/`writeLine`.
5. **Content on demand** — list navigator fetches full draft content via `getDraft(uuid:)` only when Enter is pressed, not in advance.

## Known Limitations

- **ASCII-only input** — `readKey()` only handles single-byte characters (< 128). Multi-byte UTF-8 characters (emojis, accented chars) are not handled.
- **No word wrapping** — long lines are hard-truncated to terminal width in viewer and list.
- **No mouse support** — navigation is keyboard-only.
- **No resize handling** — terminal size is fetched once. If the terminal is resized while in list/view mode, the display may be off.
- **History not persisted** — command history is lost when the REPL exits.
- **No search/aisearch result count** — the LLM response mentions relevance but the list shows all drafts, not just the relevant ones.

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

## Build

```bash
swift build -c release                    # Release build
cp .build/release/draftscript ~/.local/bin/  # Install
```

## Testing

No test suite exists yet. The tool interacts with the Drafts AppleScript API which requires the Drafts app to be installed. Testing would need mocking of the AppleScript layer or integration tests with the actual app.
