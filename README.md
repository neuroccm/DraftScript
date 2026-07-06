# draftscript

An interactive CLI tool to manage your [Drafts](https://getdrafts.com) macOS app drafts from the terminal. Use it as a one-shot command or drop into interactive REPL mode with arrow-key navigation, tab completion, and AI-powered semantic search via a local LLM — [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) (including local Gemma models), fully offline.

## Features

- **Interactive REPL** — full terminal UI with history, tab completion, and list navigation
- **Compose mode** — write or paste multi-line drafts, end with `/end` to save
- **Recent browser** — browse recent current-workspace drafts, or edit them with `/recent --edit`
- **Todo mode** — navigate and update a pinned Drafts todo draft from the REPL
- **Create** drafts from arguments, piped stdin, or compose mode
- **List** drafts with filters (folder, flagged, text search)
- **Get** a draft's full content by UUID
- **Search** drafts by text content with selectable results
- **AISearch** — semantic search via a local LLM (Ollama or LM Studio), browse results with arrow keys
- **Run** any Drafts action on a draft
- **Set tags**, toggle flags, move between folders
- **View mode** — scroll through full draft content, Esc back to results

## Requirements

- macOS (Apple Silicon or Intel)
- [Drafts](https://getdrafts.com) app installed (Mac App Store)
- Swift 5.9+ (included with Xcode or Command Line Tools)
- A local LLM backend (optional, for `aisearch`): [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai)

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
# Launch the interactive REPL
draftscript

# Or use one-shot commands directly
draftscript create "Buy groceries"
draftscript list --limit 10
draftscript search "meeting notes"
draftscript current
```

## Interactive REPL

Running `draftscript` with no arguments enters the interactive REPL — a terminal UI with a prompt, command history, tab completion, and navigable lists.

```
$ draftscript
DraftScript interactive. Type /help for commands. /exit or ^C to quit.

> /new --tags work
── Compose your draft (type /end on a blank line to save, /cancel to abort) ──
Meeting notes from today:
- Q3 roadmap discussed
- Budget approved
/end
Created: A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4

> /aisearch "design ideas"
Fetching drafts... 50 found.
Querying LLM (gemma4:e2b)...
[LLM response with relevant results]

── All drafts (↑/↓ select, Enter view, q back) ──
  a1b2c3d4  some ideas about the new feature...
→ e5f6g7h8  meeting notes from last week...
  i9j0k1l2  design brainstorm session...
```

### Slash Commands

| Command | Description |
|---------|-------------|
| `/new [--tags <t>] [--flag]` | Enter compose mode, type/paste content, end with `/end` |
| `/edit` | Select one of the 10 most recently modified drafts, edit it, and save with `/end` |
| `/recent [--limit <n>] [--edit]` | Browse recent drafts, or edit with `--edit` |
| `/todo` | Open the pinned todo draft, move with ↑/↓, toggle with Space/←/→, edit with Enter |
| `/todo --change [uuid]` | Set a different Drafts draft as the pinned todo list |
| `/list [--tag <t>] [--folder <f>] [--flagged] [--search <q>] [--limit <n>]` | List drafts |
| `/search <q> [--folder <f>] [--limit <n>]` | Search drafts, results are selectable |
| `/aisearch <q> [--limit <n>]` | AI-powered semantic search, browse results |
| `/get <uuid>` | Show a draft's full content |
| `/current` | Show the draft currently open in the editor |
| `/action <name> [--uuid <uuid>]` | Run a Drafts action |
| `/tag <uuid> <tag> ...` | Set tags on a draft |
| `/flag <uuid> [--unflag]` | Toggle flagged state |
| `/folder <uuid> <inbox\|archive\|trash>` | Move a draft to a folder |
| `/model [<name>] [--provider <ollama\|openai>] [--url <url>]` | Show or change the AI search backend, model, and endpoint |
| `/help` | Show all commands |
| `/exit` | Quit the REPL |

### Composing a Draft

```
> /new
── Compose (type /end on a blank line to save, /cancel to abort) ──
Your multi-line draft content here.
You can paste or type freely.
/end
Created: A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4
```

Options like `--tags work,urgent --flag` can be added on the `/new` line.

### Editing a Draft

```
> /edit
── Edit recent drafts (↑/↓ select, Enter edit, q back) ──
→ A2A1F93B-25D4-416B-9B5F-3D192DBE6AA4  First line of the draft
```

Select a recently modified draft with the arrow keys and press Enter. The draft opens in an editable buffer. Use arrow keys to move, Enter to insert lines, and type `/end` on its own line to overwrite the draft and return to the REPL. Use `/cancel`, Escape, or Ctrl-C to abort.

### Recent Drafts

`/recent` shows the 10 most recent drafts from the current Drafts workspace. Use the arrow keys to select a draft and press Enter to view its full content. While viewing, press `/` to open that draft in the editor, or Escape to return to the recent list.

Use `/recent --limit 5` to change the count, or `/recent --edit` to open the selected draft in the same editable buffer used by `/edit`.

### Todo List

`/todo` opens a pinned Drafts draft as a line-by-line todo list. The default todo draft is `399FDE34`, but you can change it from the REPL:

```
> /todo --change 399FDE34-ABCD-1234-ABCD-1234567890AB
```

You can also run `/todo --change` with no UUID and enter the new Drafts ID when prompted. DraftScript validates the draft, resolves short UUID prefixes to the full UUID when possible, and saves the selection in `~/.draftscript_todo_uuid` for future sessions.

In todo mode, use ↑/↓ to select a line, Space or ←/→ to toggle Markdown checkbox state, and Enter to edit the selected line. Changes are saved back to the same draft immediately.

### Navigating Results

When search or aisearch returns multiple results, a navigable list appears:

- **↑/↓** — move selection
- **Enter** — view the full draft (scroll with ↑/↓, Esc to go back)
- **q** — exit the list and return to the prompt

### Tab Completion

Press Tab to auto-complete command names. Multiple matches show all possibilities.

## One-Shot CLI Commands

All commands also work directly from the shell for scripting or quick use:

### `create`

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

`aisearch` (and `/aisearch` in the REPL) runs against a local LLM — either **Ollama** or **LM Studio** — entirely on your machine. The tool auto-detects whether the configured backend is running and falls back gracefully if it isn't.

### Option A: Ollama

1. **Install Ollama:**

   ```bash
   brew install ollama
   ```

2. **Start the Ollama service:**

   ```bash
   ollama serve
   ```

3. **Pull a Gemma model:**

   ```bash
   ollama pull gemma4
   ```

4. **Run a search:**

   ```bash
   draftscript aisearch "what did I write about design?" --limit 30
   ```

Ollama is the default backend — no configuration needed.

### Option B: LM Studio (local Gemma models)

DraftScript also speaks [LM Studio](https://lmstudio.ai)'s OpenAI-compatible local server API, so `aisearch` can run entirely against a local Gemma model (e.g. `gemma-2-9b-it`, `gemma-3-*`) loaded in LM Studio instead of Ollama.

1. Install LM Studio and download a Gemma model from its in-app model search.
2. Load the model and start LM Studio's local server (Developer / Local Server tab). By default it listens on `http://localhost:1234`.
3. Point DraftScript at it from the REPL:

   ```
   > /model gemma-2-9b-it --provider openai --url http://localhost:1234
   ```

   Use the model name exactly as LM Studio reports it — check the server tab, or `curl http://localhost:1234/v1/models`.

4. Run a search — `aisearch` / `/aisearch` now use LM Studio:

   ```bash
   draftscript aisearch "what did I write about design?" --limit 30
   ```

### Configuration

Backend settings persist to `~/.draftscript_config.json`:

```json
{
  "provider": "ollama",
  "url": "http://localhost:11434",
  "model": "gemma4:e2b"
}
```

Change any of these with `/model <name> [--provider ollama|openai] [--url <url>]` in the REPL, or edit the file directly. Settings apply to both the interactive REPL and one-shot `draftscript aisearch`.

## Pipe Support

Any command that accepts text as an argument also reads from stdin:

```bash
curl -s https://example.com/notes.txt | draftscript create --tags imported
```

## Examples

```bash
# Launch the interactive REPL
draftscript

# In the REPL: compose a new draft
> /new --tags work

# In the REPL: AI search and browse results
> /aisearch "vacation planning"

# One-shot: capture a quick thought
draftscript create "Remember to file taxes by April 15"

# One-shot: find everything in the archive with "report"
draftscript search report --folder archive

# Flag the current draft and move it to the inbox
draftscript flag $(draftscript current | head -1 | awk '{print $2}')
draftscript folder $(draftscript current | head -1 | awk '{print $2}') inbox
```

## Project Layout

```
DraftScript/
├── Package.swift                     # Swift Package Manager manifest
├── Sources/
│   └── draftscript/
│       ├── CLI.swift                 # @main entry point, command configuration
│       ├── Commands.swift            # One-shot subcommand implementations
│       ├── DraftsBridge.swift        # AppleScript execution layer
│       ├── Config.swift              # Persisted AI backend config (~/.draftscript_config.json)
│       ├── LLMService.swift          # Ollama / LM Studio (OpenAI-compatible) client for AI search
│       └── Interactive.swift         # Interactive REPL, list navigator, compose mode
└── README.md
```

## License

MIT
