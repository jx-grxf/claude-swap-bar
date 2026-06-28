# Claude Swap Bar

A native macOS menu bar app for switching between Claude Code accounts. It's a
thin, pretty front-end over the [`claude-swap`](https://github.com/realiti4/claude-swap)
CLI (`cswap`) — the CLI does the credential juggling, this app gives you a
one-click menu bar UI with live usage meters.

## Features

- Lists every managed account with org name and active state
- Live 5h / 7d usage meters (color-coded green → orange → red)
- One-click switch to any account
- Rotate to next, or smart-switch by quota (`best` / `next-available`)
- Menu-bar-only (no Dock icon)

## Requirements

- macOS 13+
- `cswap` installed and on PATH (`uv tool install claude-swap`)
- At least one account added (`cswap --add-account`)

## Build & run

```sh
# Dev run (foreground, logs to terminal)
swift run

# Build a double-clickable .app bundle
./build-app.sh
open ClaudeSwapBar.app

# Install
cp -R ClaudeSwapBar.app /Applications/
```

## How it works

`CSwapClient` shells out to `cswap … --json` and decodes the result. The app
never scrapes human-readable output — it only uses the documented JSON
interface, so it stays stable across `cswap` versions.

After switching, restart any running Claude Code session so it picks up the new
credentials. Per-terminal isolation is available via `cswap run <N>`.
