# Contributing to CSwap

Thanks for helping out. This file covers how the project is put together, how to build and test it, and the rules that keep users logged in.

## Layout

CSwap is a Swift Package with three targets:

```
Sources/
├── CSwapKit/                  # Shared core; never writes a credential
│   ├── Seat.swift             # One account ("seat"): folder, Keychain item name, running sessions
│   ├── SeatStore.swift        # Create/remove/list accounts, shared symlinks, .claude.json merge, default
│   ├── ShellIntegration.swift # zsh/bash script, startup-file lines, migration
│   ├── SessionMover.swift     # /swap and Move: end a session, resume it in another account
│   ├── SeatCredentialReader.swift  # Read-only login access, advisory lock
│   ├── SeatUsage.swift / UsageService.swift / UsageSnapshot.swift  # Usage fetch and shared cache
│   ├── ClaudeLauncher.swift   # Starts `claude` in an account
│   └── TerminalLauncher.swift # New terminal windows (Ghostty or Terminal.app)
├── cswap/                     # The command-line tool, bundled at CSwap.app/Contents/MacOS/cswap
└── CSwapBar/                  # The menu bar app (MenuBarExtra, LSUIElement)
    ├── Services/              # AppState, file watcher, Sparkle updates
    ├── Settings/              # Settings window
    └── Views/                 # Popover, account rows, add-account sheet
```

Sparkle is the only third-party dependency and stays pinned exactly in `Package.swift` and `Package.resolved`.

## Build and run

```sh
swift build                          # compile everything
./script/build_and_run.sh            # build CSwap.app and launch it
./script/build_and_run.sh --verify   # build, launch, check it stays up
./script/build_and_run.sh --logs     # launch and stream the app's logs
```

`./build-app.sh` builds `CSwap.app`, ad-hoc signed by default. Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for distribution. For packaging changes, also run:

```sh
./build-app.sh
codesign --verify --deep --strict CSwap.app
```

SwiftPM resources are flattened into `CSwap.app/Contents/Resources`. Packaged code loads resources from `Bundle.main`; `Bundle.module` is only a fallback during development.

## Testing without touching your real accounts

`cswap` honors two variables for tests:

- `CSWAP_HOME=<scratch dir>` moves every account path (`~/.claude`, `~/.cswap`, startup files) into a scratch folder.
- `CSWAP_CLAUDE=<stand-in>` replaces the `claude` binary, so no real login or browser opens.

Don't override `HOME` for this: `security` finds the login Keychain through `HOME`. For `/swap` and Move, the stand-in must be a native binary named `claude` that writes `<config>/sessions/<pid>.json`; CSwap only ever signals processes that look like Claude Code.

## Rules that keep people logged in

- Never write, refresh, copy or restore an OAuth credential. Claude Code owns each account's single-use refresh token; CSwap only reads the current access token to show usage. Swapping credentials is what made earlier switchers log people out.
- Take Claude Code's advisory lock (the `<.claude.json>.lock` directory) when merging into an account's `.claude.json`.
- Account folders, the usage cache (`~/Library/Application Support/CSwap`) and Keychain output never belong in fixtures, logs or commits.
- Don't log tokens, authorization headers or account JSON.

## Style

- Follow the existing Swift and SwiftUI structure; keep changes focused.
- English for code, UI text, commits and release notes.
- Conventional Commits (`feat:`, `fix(cli):`, `docs:` …), one topic per branch: `<type>/<short-description>`.

## Releases

Each release needs reviewed notes committed before its tag:

1. Set `VERSION` to `X.Y.Z` (or `X.Y.Z-beta.N`).
2. Write `release-notes/vX.Y.Z.md`; the file name must match the tag.
3. Run the build and signing checks above.
4. Commit, then push a signed, annotated `vX.Y.Z` tag.

The release workflow builds, signs with Developer ID, notarizes, staples and publishes `CSwap-X.Y.Z.zip` plus a signed Sparkle `appcast.xml`. Beta tags also update the moving `beta` feed. It needs these repository settings:

- Secrets: `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` (Developer ID certificate), `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` (notarization), `CSWAPBAR_SPARKLE_PRIVATE_KEY` (update signing).
- Variable: `CSWAPBAR_SPARKLE_PUBLIC_KEY`.

Never rotate the Sparkle key casually: installed copies trust the public key they shipped with.
