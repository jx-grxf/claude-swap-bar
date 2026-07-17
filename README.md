<div align="center">

# Claude Swap Bar

**Native macOS menu bar app for switching between Claude Code accounts.**

[![CI](https://github.com/jx-grxf/claude-swap-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/jx-grxf/claude-swap-bar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jx-grxf/claude-swap-bar?color=informational)](https://github.com/jx-grxf/claude-swap-bar/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)

*One click to switch accounts. Live usage meters. Zero external tools.*

</div>

---

## What it does

Claude Swap Bar manages multiple Claude Code logins and switches between them from the menu bar. It is fully self-contained: accounts live in the app's own vault (tokens in the macOS Keychain), and switching writes credentials directly to the same places Claude Code reads them from — the `Claude Code-credentials` Keychain item and `~/.claude.json`. No Python, no CLI, no subprocess juggling.

- **One-click switching** — click an account, done. A running Claude Code session picks the change up within ~30 seconds, or immediately after a restart.
- **Live usage meters** — 5-hour, 7-day, and per-model windows per account, color-coded, with reset countdowns.
- **Honest failure states** — instead of a blanket "usage unavailable" you see *why*: rate-limited, offline, or session expired.
- **Rotate & Best Quota** — cycle to the next account, or jump straight to the one with the most 5h headroom.
- **Guided add-account flow** — the app detects new Claude Code logins and captures them with one click.
- **Settings** — refresh interval, launch at login, menu bar usage display.
- **Automatic migration** — existing [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`) accounts are imported on first launch, credentials included. No re-login.

## Install

Grab the signed app from the [latest release](https://github.com/jx-grxf/claude-swap-bar/releases/latest), unzip, and drop it into `/Applications`.

Or build from source (macOS 14+, Xcode command line tools):

```sh
git clone https://github.com/jx-grxf/claude-swap-bar.git
cd claude-swap-bar
./build-app.sh
cp -R ClaudeSwapBar.app /Applications/
open /Applications/ClaudeSwapBar.app
```

## Adding accounts

1. Click **＋** in the menu bar popover.
2. If the current Claude Code login isn't managed yet, add it with one click.
3. For additional accounts: run `claude /login` in a terminal, sign in with the other account, and the app detects it automatically.

Your previous account stays safely stored — switch back any time.

## How switching works

Each account's OAuth credentials are stored in per-account Keychain items plus a small JSON vault in `~/Library/Application Support/ClaudeSwapBar/`. On switch, the app:

1. Syncs back whatever tokens Claude Code currently holds (so the outgoing account keeps its freshest refresh-token lineage).
2. Refreshes the target account's token if it is about to expire.
3. Takes Claude Code's own advisory locks (`~/.claude.lock`, `~/.claude.json.lock`) so it never races a live session's token refresh.
4. Writes the target credentials to the `Claude Code-credentials` Keychain item (via `/usr/bin/security`, matching Claude Code's own access path) and splices the account profile into `~/.claude.json` — everything else in that file is preserved.

Expired access tokens of *inactive* accounts are refreshed automatically in the background. The active account's token is deliberately left alone while Claude Code is running — Claude Code owns and refreshes it itself.

## Usage meters and the rate limit

The usage endpoint allows roughly 30 requests per hour per account. The app polls gently (default every 5 minutes, 3-minute cache), backs off on 429 and honors `Retry-After`. If another tool (e.g. a still-running `cswap` TUI) burns the same budget, meters can be temporarily rate-limited — the row will say so instead of silently showing nothing.

## Project layout

```
Sources/ClaudeSwapBar/
├── ClaudeSwapBarApp.swift        # MenuBarExtra entry point
├── Models/                       # Account, usage snapshots
├── Services/
│   ├── AppState.swift            # Central state: accounts, usage, switching
│   ├── Vault.swift               # Own account store (JSON + Keychain)
│   ├── ClaudeCodeBridge.swift    # Reads/writes Claude Code's credential surfaces
│   ├── OAuthService.swift        # Token refresh
│   ├── UsageService.swift        # Usage endpoint client
│   └── CSwapImporter.swift       # One-time migration from cswap
├── Settings/                     # Settings window (General / Menu Bar / About)
└── Views/                        # Menu popover, account rows, add-account flow
```
