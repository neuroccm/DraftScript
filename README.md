# draftscript

A CLI tool to interact with the [Drafts](https://getdrafts.com) macOS app from the terminal. Uses AppleScript for full read/write access to your draft library. Optionally integrates with [Ollama](https://ollama.com) + **Gemma 4** for AI-powered semantic search.

## Features

- **Create** drafts from arguments or piped stdin
- **List** drafts with filters (folder, flagged, text search)
- **Get** a draft's full content by UUID
- **Show** the current draft in the editor
- **Search** drafts by text content
- **AISearch** — semantic search via a local LLM
- **Run** any Drafts action on a draft
- **Set tags**, toggle flags, move between folders

## Requirements

- macOS (Apple Silicon or Intel)
- [Drafts](https://getdrafts.com) app installed (Mac App Store)
- Swift 5.9+ (for building from source, included with Xcode or Command Line Tools)
- [Ollama](https://ollama.com) (optional, for `aisearch`)

## Installation

```bash
git clone <this-repo> ~/DraftScript
cd ~/DraftScript
swift build -c release
cp .build/release/draftscript ~/.local/bin/
```

Ensure `~/.local/bin` is in your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## One-Time Permission

Before `draftscript` can communicate with Drafts, grant AppleScript permission:

1. Open **System Settings** → **Privacy & Security** → **Automation**
2. Click **+** and add your terminal app (Terminal, iTerm2, Warp, etc.)
3. Check the box next to **Drafts**
4. Run any command (e.g. `draftscript list`) to verify

## Quick Start

```bash
draftscript create "Buy groceries"

draftscript list --limit 10

draftscript search "meeting notes"

draftscript current
```

## Command Reference

### `create`

Create a new draft.

```
draftscript create [<text>] [--tags <tags>] [--folder <folder>] [--flag]
```

| Argument/Option | Description |
|---|---|
| `text` | Draft content. Omit to pipe from stdin. |
| `--tags` | Comma-separated tags (e.g. `work,urgent`) |
| `--folder` | Target folder: `inbox`, `archive`, or `trash` |
| `--flag` | Flag the draft |

**Examples:**

```bash
draftscript create "Meeting at 3pm" --tags work --flag
echo "Piped note" | draftscript create
```

### `list`

List drafts with optional filters.

```
draftscript list [--tag <tag>] [--folder <folder>] [--flagged] [--search <query>] [--limit <n>]
```

| Option | Description |
|---|---|
| `--tag` | Filter by tag |
| `--folder` | Filter by folder (`inbox`, `archive`, `trash`) |
| `--flagged` | Show only flagged drafts |
| `--search` | Filter by text in content |
| `--limit` | Max results (default: 50) |

**Example:**

```bash
draftscript list --folder inbox --flagged --limit 20
```

### `get`

Get a draft's full content by UUID.

```
draftscript get <uuid>
```

**Example:**

```bash
draftscript get A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4
```

### `current`

Show the draft currently open in the editor.

```
draftscript current
```

### `search`

Full-text search across draft content.

```
draftscript search <query> [--folder <folder>] [--limit <n>]
```

**Example:**

```bash
draftscript search "project alpha" --folder inbox --limit 5
```

### `aisearch`

Semantic search using a local LLM via Ollama. Drafts are sent to the model for relevance ranking.

```
draftscript aisearch <query> [--limit <n>] [--verbose]
```

| Option | Description |
|---|---|
| `--limit` | Number of recent drafts to consider (default: 50) |
| `--verbose` | Show all drafts before the LLM response |

**Example:**

```bash
draftscript aisearch "ideas about the new feature" --limit 30
```

### `action`

Run a Drafts action on a draft.

```
draftscript action <name> [--uuid <uuid>]
```

| Argument/Option | Description |
|---|---|
| `name` | Name of the action (e.g. "Copy", "Archive") |
| `--uuid` | Target draft UUID (defaults to current draft) |

**Example:**

```bash
draftscript action "Archive" --uuid A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4
```

### `tag`

Set tags on a draft (replaces all existing tags).

```
draftscript tag <uuid> <tag> [<tag> ...]
```

**Example:**

```bash
draftscript tag A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4 work urgent
```

### `flag`

Toggle the flagged state of a draft.

```
draftscript flag <uuid> [--unflag]
```

**Example:**

```bash
draftscript flag A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4
draftscript flag A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4 --unflag
```

### `folder`

Move a draft to a different folder.

```
draftscript folder <uuid> <inbox|archive|trash>
```

**Example:**

```bash
draftscript folder A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4 archive
```

## AI Search Setup

1. **Install Ollama:**

   ```bash
   brew install ollama
   ```

2. **Start the Ollama service:**

   ```bash
   ollama serve
   ```

3. **Pull a Gemma 4 model:**

   ```bash
   ollama pull gemma4
   ```

4. **Run a search:**

   ```bash
   draftscript aisearch "what did I write about design?" --limit 30
   ```

The tool auto-detects whether Ollama is running and falls back gracefully if it isn't.

## Pipe Support

Any command that accepts text as an argument also reads from stdin:

```bash
curl -s https://example.com/notes.txt | draftscript create --tags imported
```

## Examples

```bash
# Capture a quick thought
draftscript create "Remember to file taxes by April 15"

# Find everything in the archive with "report"
draftscript search report --folder archive

# Flag the current draft and move it to the inbox
draftscript flag $(draftscript current | head -1 | awk '{print $2}')
draftscript folder $(draftscript current | head -1 | awk '{print $2}') inbox

# Semantic search with the most recent 100 drafts
draftscript aisearch "vacation planning" --limit 100
```

## Project Layout

```
DraftScript/
├── Package.swift              # Swift Package Manager manifest
├── Sources/
│   └── draftscript/
│       ├── CLI.swift           # @main entry point, command configuration
│       ├── Commands.swift      # All 10 subcommand implementations
│       ├── DraftsBridge.swift  # AppleScript execution layer
│       └── LLMService.swift    # Ollama API client for AI search
└── README.md
```

## License

MIT
