# Tidey Architecture Notes

## Goal

Tidey is not trying to replace iTerm2's terminal core.

The goal is:

- keep iTerm2's mature terminal stack intact
- keep iTerm2's native `tmux -CC` behavior intact
- add Tidey-specific product shell on top:
  - left sidebar for agent tree and notifications
  - right editor panel
  - cmd-click or similar file-open workflow into the editor
  - AI-agent-specific workflow affordances

This document records where those seams appear to be in the current iTerm2 codebase.

## Core Class Map

### Application Entry

- `sources/main.m`
- `sources/iTermApplicationDelegate.{h,m,swift}`

`main.m` enters AppKit through `NSApplicationMain`. `iTermApplicationDelegate` is the real application-level delegate and startup coordinator.

This is the right layer to understand:

- app startup
- global menus
- top-level services
- app-wide wiring

It is **not** the right first place to attach Tidey panels.

## App-Level Coordination

### `iTermController`

- `sources/iTermController.{h,m}`

This is the main app-level coordinator for terminal windows, sessions, and tmux-related window creation.

Important signals:

- singleton controller
- tracks current terminal/window/session state
- contains explicit tmux integration entry points such as `openTmuxIntegrationWindowUsingProfile:...`

For Tidey, this is an important orchestration class, but not the first UI extension seam.

## Window-Level Shell

### `PseudoTerminal`

- `sources/PseudoTerminal.{h,m}`

This is the most important Tidey extension seam found in Milestone 0.

`PseudoTerminal` is a window controller responsible for:

- tabs
- fullscreen and window behavior
- window-level content layout
- toolbelt integration
- tmux integration window handling

Evidence:

- `PseudoTerminal.h` exposes `toolbelt`
- `PseudoTerminal.m` contains toolbelt arrangement, visibility, resizing, and window content coordination

This makes `PseudoTerminal` the best first candidate for adding Tidey shell UI around the existing terminal content.

### Recommendation

Treat `PseudoTerminal` as the likely home for:

- left sidebar container
- right editor container
- window-level Tidey layout state

In other words:

- do **not** start by modifying terminal emulation classes
- start by extending the window shell around them

## Tab and Split Layout

### `PTYTab`

- `sources/PTYTab.{h,m}`

`PTYTab` owns sessions within a tab and manages split layout behavior.

Important signs:

- owns active session in a tab
- has tmux-related size/layout concerns
- uses `PTYSplitView`
- exposes methods around split behavior and session navigation

### `PTYSplitView`

- `sources/PTYSplitView.{h,m}`

This is the split container layer for panes within a tab.

It matters for Tidey because any editor or sidebar integration must not accidentally break:

- split layout
- pane resizing
- tmux-integrated tabs

### Recommendation

Do not try to replace `PTYTab` / `PTYSplitView`.

Instead:

- let iTerm2 continue to own pane layout
- add Tidey UI outside that layout, at the window shell level

## Session-Level Integration

### `PTYSession`

- `sources/PTYSession.{h,m}`

`PTYSession` is the session-level workhorse.

It owns or coordinates:

- task / PTY lifecycle
- session state
- text view interaction
- browser-mode behavior
- tmux session/client behavior
- status bar relationships

Important clue:

- `PTYSession.h` exposes `mainResponder`, documented as "textView or browser vc depending on mode"

That means iTerm2 already supports more than one "content mode" inside a session.

This is useful for Tidey in two ways:

1. file-open and editor actions likely need a session-aware hook here
2. the existing browser/session-mode patterns are good references for adding adjacent non-terminal UI

## Terminal Core

### `VT100Terminal`

- terminal parser / emulation semantics

### `VT100Screen`

- screen model
- scrollback
- marks
- prompt/shell integration related state

These classes are exactly where Tidey's Ghostty effort got stuck before:

- DCS handling
- viewport correctness
- scrollback fidelity
- clone/bootstrap behavior

### Recommendation

For Tidey, these classes should be treated as **protected core**.

Do not start customization here unless there is a proven upstream bug that cannot be solved elsewhere.

The whole point of moving to iTerm2 is to stop rebuilding terminal correctness from scratch.

## Existing Extension Patterns in iTerm2

### Toolbelt

- `iTermToolbeltView`
- `PseudoTerminal` integration

This is the strongest proof that iTerm2 already supports window-adjacent auxiliary UI.

Tidey's sidebar should study this path first.

### Browser Mode

- `iTermBrowserPlugin`
- browser-related code under `sources/Browser/`
- browser-aware behavior in `PTYSession`

This shows iTerm2 already tolerates non-terminal content modes and hybrid session behavior.

Tidey's right editor panel is not the same as browser mode, but browser mode is still a useful reference for:

- panel/controller boundaries
- focus/responder management
- session-aware non-terminal UI

### AI

- `iTermAI/`

This is relevant because Tidey also wants AI-native workflow, but Tidey should not assume iTermAI is the right abstraction seam. It is better treated as a reference implementation for adding product features to iTerm2 than as a base architecture.

### Status Bar

- `iTermStatusBar*`
- tmux-aware status classes such as `iTermTmuxStatusBarMonitor`

Useful reference for session-aware UI and tmux-aware state propagation.

## Recommended Tidey Extension Strategy

### Phase 1: Prove a Window-Level Shell

First proof of concept:

- add a left sidebar to an iTerm2 window
- do not modify terminal core
- do not modify tmux core
- do not start with editor or browser replacement

Goal:

- prove that Tidey can own part of the window chrome without destabilizing terminal behavior

### Phase 2: Add Agent Sidebar

Add:

- agent tree
- agent notifications
- session-aware navigation hooks

This should remain primarily a `PseudoTerminal` / window-shell feature.

### Phase 3: Add Right Editor Panel

Add:

- file-open target
- editor host
- save / reload flow
- syntax highlighting and editing UX

This should integrate with session/file-open actions, but should still avoid touching `VT100*` classes unless absolutely necessary.

### Phase 4: Connect Terminal Actions to Tidey UI

Examples:

- cmd-click file path opens in Tidey editor panel
- agent notifications focus the relevant session/tab/window
- session metadata drives sidebar badges and routing

Likely seam:

- session-level actions in `PTYSession`
- window/tab-level routing in `PseudoTerminal` and `iTermController`

## First Places To Read Next

If Tidey moves into Milestone 1, the most useful files to study next are:

1. `sources/PseudoTerminal.m`
2. `sources/PTYSession.m`
3. `sources/PTYTab.m`
4. `sources/PTYSplitView.m`
5. `sources/iTermToolbeltView.*`
6. browser-related classes under `sources/Browser/`

## Working Rule

When in doubt:

- extend `PseudoTerminal`
- integrate through `PTYSession`
- leave `VT100Terminal` and `VT100Screen` alone

That is the cleanest way to preserve iTerm2's strengths while turning it into Tidey.
