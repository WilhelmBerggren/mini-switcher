<h1 align="center">
  <img src="icon.png" width="120" alt="MiniSwitcher icon"><br>
  MiniSwitcher
</h1>

<p align="center">A tiny macOS window switcher — a mini version of <a href="https://github.com/lwouis/alt-tab-macos">AltTab</a>.</p>

<p align="center">
  <img src="preview.png" width="560" alt="MiniSwitcher showing a list of open windows">
</p>


macOS's built-in `⌘Tab` switches between *applications*. AltTab famously replaces
it with a switcher over individual *windows*, the way Windows and most Linux DEs
work. MiniSwitcher is a deliberately small take on that idea: a single Swift file,
no dependencies, no build system beyond `swiftc` and `make`. It exists to show how
little code the core of a window switcher actually takes — list every on-screen
window with its title and icon, and raise the one you pick.

## Features

- Press `⌘Tab` to pop up a list of all open **windows** (not just apps), each with
  its title and app icon.
- Hold `⌘` and tap `Tab` to move forward, `⇧Tab` to move backward.
- `↑`/`↓` to navigate, `Return` to switch, `Esc` to dismiss.
- **Click any row to switch to it instantly**, even while `⌘` is still held.
- Releasing `⌘` commits the highlighted window — the familiar `⌘Tab` muscle memory.
- Lives in the menu bar (no Dock icon); the system `⌘Tab` is taken over while
  running and restored when you quit.

## Requirements

- macOS 13 (Ventura) or later.
- The Swift toolchain (Xcode or the Command Line Tools: `xcode-select --install`).
- **Accessibility permission** — needed to read window titles and to raise the
  selected window. macOS will prompt on first launch; you can also grant it under
  *System Settings → Privacy & Security → Accessibility*, or via the menu-bar
  item's *Grant Accessibility Access…* entry. Without it, the list falls back to
  showing app names only.

## Build & run

```sh
make build   # compile main.swift and assemble MiniSwitcher.app
make run     # build, then launch the app
make clean   # remove build artifacts
```

`make build` compiles `main.swift`, generates the app icon from an SF Symbol
(once, via `generate_icon.swift`), assembles `MiniSwitcher.app`, and ad-hoc
code-signs it. The signing step pins the bundle's *designated requirement* to the
bundle identifier rather than the binary hash, so the Accessibility grant survives
rebuilds — you don't have to re-approve the app every time you recompile.

After the first `make run`, grant Accessibility access when prompted, then trigger
`⌘Tab`.

## How it works

The interesting bits live in `main.swift`:

- **Window list** comes from `CGWindowListCopyWindowInfo` (on-screen, non-desktop
  windows).
- **Window titles** come from the Accessibility API. The tricky part is matching an
  `AXUIElement` back to a `CGWindowID`; the public AX API has no attribute for this,
  so MiniSwitcher uses the private `_AXUIElementGetWindow` symbol — the same approach
  AltTab uses. A `CGSCopyWindowProperty` window-server read is kept as a fallback.
- **Taking over `⌘Tab`** is done by disabling the system symbolic hotkey
  (`CGSSetSymbolicHotKeyEnabled`) and registering our own Carbon hotkey. This change
  persists across process exits, so it's restored on quit and on `SIGINT`/`SIGTERM`.

These rely on private/undocumented system symbols, which is why this is a learning
toy rather than something to ship. For a real, robust, configurable switcher, use
[AltTab](https://github.com/lwouis/alt-tab-macos).
