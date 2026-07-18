# Repository Instructions

## Project

Claude Swap Bar is a native macOS 14+ SwiftUI menu bar app for managing and switching Claude Code accounts. It is a Swift Package Manager executable with no third-party dependencies.

The app is intentionally menu-bar-only (`MenuBarExtra`, `LSUIElement`, accessory activation policy). A successful launch shows a menu bar item; it does not create a Dock icon or a normal main window.

## Required workflow

- Inspect `git status`, the current branch, and relevant files before editing.
- Preserve unrelated user changes.
- Use a focused `<type>/<short-description>` branch for non-trivial work.
- Follow the existing Swift and SwiftUI architecture; keep changes scoped.
- Use English for source code, UI copy, commits, tags, release notes, and other published artifacts.
- Use Conventional Commit messages and signed commits when signing is configured.
- Never commit credentials, OAuth tokens, signing certificates, App Store Connect keys, or local vault data.

## Build and verification

Use the project entrypoint instead of ad hoc build and launch commands:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
```

Before completing a code change, run at minimum:

```sh
swift build
./script/build_and_run.sh --verify
```

For packaging changes, also verify:

```sh
./build-app.sh
codesign --verify --deep --strict ClaudeSwapBar.app
```

SwiftPM resources are flattened into `ClaudeSwapBar.app/Contents/Resources` by `build-app.sh`. Packaged resource loading must use `Bundle.main`; direct SwiftPM development may fall back to `Bundle.module`. Do not place resource bundles beside `Contents`, because that creates an invalid app bundle for code signing.

## Source layout

- `Sources/ClaudeSwapBar/ClaudeSwapBarApp.swift`: app entry point and menu bar scene.
- `Sources/ClaudeSwapBar/Services`: account vault, Keychain, Claude Code bridge, OAuth, and usage logic.
- `Sources/ClaudeSwapBar/Views`: menu bar content and account interactions.
- `Sources/ClaudeSwapBar/Settings`: settings UI and activation-policy handling.
- `build-app.sh`: release bundle construction and signing.
- `script/build_and_run.sh`: canonical local build, launch, debug, and verification entrypoint.
- `.github/workflows`: CI and release automation.
- `release-notes`: versioned GitHub Release descriptions.

## Release process

Every release must have a reviewed Markdown file committed before its tag is created:

```text
release-notes/vX.Y.Z.md
```

The filename must exactly match the release tag. Write concise user-facing sections such as highlights, fixes, and installation notes. Do not rely on GitHub-generated notes and do not create a release with an empty or placeholder file.

Before tagging a release:

1. Update `VERSION` in `build-app.sh` to `X.Y.Z`.
2. Create and review `release-notes/vX.Y.Z.md`.
3. Run the build, launch, and code-signing verification commands above.
4. Commit all release inputs.
5. Create an SSH-signed annotated `vX.Y.Z` tag and push it.

The release workflow fails when the matching notes file is absent or empty. It uses that file for both newly created releases and reruns that update an existing release, then uploads the signed/notarized ZIP.

## Security and data handling

- Account metadata lives in `~/Library/Application Support/ClaudeSwapBar` and tokens live in macOS Keychain; neither belongs in fixtures, logs, or commits.
- Preserve Claude Code advisory locking and refresh-token ownership semantics when changing account switching.
- Keep release signing and notarization material in GitHub Actions secrets only.
- Avoid logging credential payloads, authorization headers, account JSON, or Keychain output.
