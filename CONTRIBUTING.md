# Contributing to Spotcat

Thanks for your interest in improving Spotcat! This guide covers local setup and how to get a
change merged.

## Prerequisites

- macOS 13 or later (developing on macOS 26 is recommended)
- Swift 5.9+ — Xcode, or just the Command Line Tools (`xcode-select --install`)
- The macOS 26 SDK to compile the system-translation code path
- Optional: `brew install librsvg` to regenerate icons

## Setup

```bash
git clone git@github.com:thinkany-ai/spotcat.git
cd spotcat
make run        # builds build/Spotcat Dev.app and launches it
```

Local builds are **Spotcat Dev** (bundle ID `ai.thinkany.spotcat.dev`, data in
`~/Library/Application Support/Spotcat Dev`, hotkey ⌥⇧Space), isolated from an installed release.
`make debug` builds a debug bundle. `swift build` alone compiles, but features that need bundle
resources (icons, the chat page) only work from the `.app`. `make dev` also loads extensions live
from a sibling checkout of [spotcat-extensions](https://github.com/thinkany-ai/spotcat-extensions)
(`../spotcat-extensions/extensions`, or set `SPOTCAT_EXTENSIONS_DIR`).

## Code style

- Match the surrounding code: naming, comment density, and idioms. Comments explain *why*, not
  *what*.
- UI is AppKit; SwiftUI is used for the settings window. With only the Command Line Tools there
  are no SwiftUI macro plugins, so use `ObservableObject` / `@Published` instead of `@State` or
  `@Observable`.
- User-facing strings go through `L10n.t(...)` (Swift) or `spotcat.i18n.t(...)` (web pages), with
  both `zh-Hans` and `en` entries.
- Keep the search path fast: no blocking work on keystrokes; long-running work (file search,
  network) must be asynchronous.

## Extensions

Extensions are not bundled with the app; they live in
[spotcat-extensions](https://github.com/thinkany-ai/spotcat-extensions) and are installed from the
in-app store (`ExtensionStore.swift`). When adding a native capability to `window.spotcat`, update
`SpotcatRuntime.swift` and `ExtensionAPI.swift` here, and `spotcat.d.ts`, `docs/development.md` and
the agent skill in spotcat-extensions; gate anything sensitive behind a manifest permission.

## Pull requests

1. Fork and create a branch from `main`.
2. Keep the change focused; describe *what* and *why* in the PR, with screenshots for UI changes.
3. Make sure `./scripts/bundle.sh release --universal` succeeds (CI runs the same build).
4. Test the change in the running app: launcher, settings, and — if touched — extensions and
   chat in both light and dark appearance.

By submitting a pull request you agree that your contribution is licensed under the project's
license (AGPL-3.0).

## Reporting bugs

Open an issue with your macOS version, Spotcat version (*Settings › About*), steps to reproduce,
and what you expected. For security issues, see [SECURITY.md](SECURITY.md) instead.
