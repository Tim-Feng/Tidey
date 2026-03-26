# 🌊 Tidey — the Terminal IDE

> Where context flows between agent and code, like the tide.

Traditional IDEs start from files. Tidey starts from the terminal. In the age of agentic coding, your CLI *is* your IDE — agents run commands, edit files, and ask for your input in a continuous cycle. Tidey is built for this flow.

<!-- TODO: hero screenshot -->

## Why Tidey

Every AI coding tool bolts a chat panel onto a file editor:

```
Traditional:   [File Tree] → [Editor] → [Agent Chat]
Tidey:         [Workspaces] → [Terminal] → [Editor]
```

The terminal is the center. The editor opens when you need it, closes when you don't.

Agents run in workspaces you can see, switch between, and monitor — not in a hidden sidebar.

## Features

**Workspace Sidebar**
- Each workspace is an agent session — Claude Code, Codex, or plain shell
- Notification badges when an agent needs your input
- Agent status (Running / Idle) displayed inline
- Drag to reorder, pin, rename, right-click context menu

**Editor Panel**
- Monaco editor with syntax highlighting, search (cmd+F)
- Opens on cmd+click from terminal — file tree auto-reveals
- Preview tabs replaced on browse, double-click to pin
- Offline — Monaco bundled locally, no CDN

**Agent Integration**
- Unix socket API for agent-to-IDE communication
- Notifications — agents send alerts with title + body
- Status — shell hooks auto-detect Running / Idle via precmd/preexec
- Works transparently inside tmux

**Terminal**
- Built on iTerm2's terminal emulation
- tmux -CC control mode support
- Collapsible terminal, editor, sidebar, file tree — all independently resizable
- Double-click divider to reset layout

## Install

<!-- TODO: DMG download link -->

**Build from source:**

```bash
git clone https://github.com/Tim-Feng/Tidey.git
cd Tidey
make setup
make Development
```

Requires Xcode and [rustup](https://rustup.rs).

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New Workspace | cmd+N |
| New Panel | cmd+T |
| Close | cmd+W |
| Switch Workspace 1/2/3 | cmd+1/2/3 |
| Next/Previous Workspace | ctrl+cmd+] / [ |
| Toggle Sidebar | cmd+B |
| Toggle Editor | cmd+shift+E |
| Toggle File Tree | ctrl+cmd+F |
| Find in Editor | cmd+F |
| Reset Layout | double-click divider |

## For Agent Developers

Tidey exposes a Unix socket API for agent-to-IDE communication — notifications, status updates, and more. See [docs/socket-api.md](docs/socket-api.md).

## Built on iTerm2

Tidey is a fork of [iTerm2](https://iterm2.com) by George Nachman. The terminal emulation, PTY management, and tmux integration come from iTerm2. The workspace model, editor panel, notification system, and socket API are Tidey originals.

## License

GPL v2-or-later — same as iTerm2.
