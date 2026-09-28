<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Spotcat">
</p>

<h1 align="center">Spotcat</h1>

<p align="center">
  <strong>A fast, native launcher for macOS — apps, files, the web, extensions and AI in one box.</strong>
</p>

<p align="center">
  <a href="https://github.com/thinkany-ai/spotcat/releases"><img src="https://img.shields.io/github/v/release/thinkany-ai/spotcat?include_prereleases&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <a href="https://github.com/thinkany-ai/spotcat/actions/workflows/ci.yml"><img src="https://github.com/thinkany-ai/spotcat/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
</p>

<p align="center">
  <a href="https://spotcat.ai">spotcat.ai</a> · English · <a href="README.zh-CN.md">简体中文</a>
</p>

---

Press **⌥Space**, type, press **↩**. Spotcat is a Spotlight / Raycast-style launcher written in
Swift and AppKit: the search panel is native, fast and small, while extensions are plain
HTML/JS so anyone can write one.

## Features

- **Apps** — fuzzy search with word-boundary and acronym matching (`vsc` → Visual Studio Code),
  pinyin for Chinese names (`wyy` → 网易云音乐), frequently used apps rank first.
- **Files** — `file: report` searches your home folder through the Spotlight index, grouped by
  folder; wildcards (`file: *.dmg`, `douchat*.dmg`) and path browsing with Tab completion
  (`file: ~/Down` ⇥). Typing something that looks like a file name suggests a file search.
- **Web** — type a URL (`github.com`, `localhost:3000`) to open it; quicklinks such as
  `gh spotcat` or `g weather`; any text can be searched with your default engine.
- **AI chat** — ask anything from the search box, or continue from an extension's result with its
  context attached. Streaming replies, Markdown, any OpenAI-compatible API (bring your own key).
- **Extensions** — built with HTML/CSS/JS, triggered by keywords or by content (regex). Built-in:
  URL/Base64 codec and a multi-engine translator (system translation, Google, AI).
- **Native feel** — non-activating floating panel, global hotkey, light/dark themes,
  English and Simplified Chinese, launch at login, draggable window that remembers its position.

## Install

Download the latest `Spotcat-x.y.z.dmg` from [Releases](https://github.com/thinkany-ai/spotcat/releases),
open it and drag **Spotcat** to Applications. Builds are universal (Apple silicon + Intel),
signed with a Developer ID and notarized by Apple.

Requires **macOS 13 Ventura** or later. System translation needs macOS 26.

## Usage

| Key | Action |
|---|---|
| **⌥Space** | Show / hide Spotcat (configurable) |
| **↑ ↓ ← →** | Move the selection |
| **↩** | Open / run the selected item |
| **⌘↩** | Reveal the selected app or file in Finder |
| **⇥** | Complete a path, or switch folder in file search |
| **Esc** | Clear the query, leave an extension or chat, then hide |
| **⌘,** | Settings |

| Type | Result |
|---|---|
| `cal` | Apps, extensions and commands |
| `file: invoice` · `file: *.pdf` · `file: ~/Downloads/` | File search / path browsing |
| `github.com` · `gh spotcat` · `wiki cats` | Open a URL or a quicklink |
| `%E4%BD%A0` · `SGVsbG8=` · any text | Suggestions: decode, translate, Ask AI, web search |
| `settings` / `设置` | Open Spotcat settings |

**AI** — set a provider, base URL, API key and model in *Settings › AI*. Keys are stored locally in
`~/Library/Application Support/Spotcat/ai.json` (file mode 600) and only sent to the provider you configure.

## Extensions

An extension is a folder with a `manifest.json` and an `index.html`:

```
my-extension/
├── manifest.json   features, keywords, content-match rules, permissions
├── index.html      the page shown when a feature is opened (runs in WKWebView)
├── locales/        optional translations (en.json, zh-Hans.json …)
└── main.js / style.css
```

Pages talk to Spotcat through `window.spotcat` — clipboard, storage, CORS-free `fetch`
(`network` permission), language detection, system translation, text-to-speech, the user's AI
provider (`ai` permission) and `spotcat.chat.open()` to hand results to the built-in chat.

Put your extension in `~/Library/Application Support/Spotcat/Extensions/` (a symlink works) and
reload it from *Settings › Extensions*. See **[extensions/README.md](extensions/README.md)** for the
full manifest reference and API, and [`extensions/spotcat.d.ts`](extensions/spotcat.d.ts) for types.

## Build from source

Requirements: macOS 13+, Swift 5.9+ (Xcode or the Command Line Tools), and the **macOS 26 SDK**
to compile the system-translation code path.

```bash
git clone https://github.com/thinkany-ai/spotcat.git
cd spotcat
make run          # build → build/Spotcat Dev.app (ad-hoc signed) → launch
```

| Command | What it does |
|---|---|
| `make build` / `make debug` | Build `build/Spotcat Dev.app` for this Mac |
| `make universal` | Universal (arm64 + x86_64) build |
| `make release` | Sign, notarize and package DMG + ZIP into `dist/` (maintainers) |
| `make icons` | Regenerate icons from `Resources/Icon/*.svg` (needs `brew install librsvg`) |
| `SPOTCAT_CHANNEL=release make build` | Build the release flavor `build/Spotcat.app` locally (unsigned) |

Local builds are **Spotcat Dev**: a separate bundle ID (`ai.thinkany.spotcat.dev`), data folder
(`~/Library/Application Support/Spotcat Dev`), default hotkey (⌥⇧Space), an amber icon and a DEV badge in the panel, so
developing never touches an installed release and both can run side by side. `make release`
(and CI) build the regular **Spotcat**.

With only the Command Line Tools installed, SwiftUI macros are unavailable — use
`ObservableObject` instead of `@State` / `@Observable`.

## Project layout

```
Sources/Spotcat/
├── AppDelegate.swift            entry point, menus, hotkey
├── LauncherController.swift     search panel: queries, sections, navigation
├── ResultsGridView.swift        icon grid       FileTreeView.swift   file results
├── AppIndex.swift · FileSearch.swift · Quicklinks.swift · FuzzyMatcher.swift
├── Extensions/                  manifest model, loader, host view, native API
├── Chat/ · AIService.swift      built-in AI chat and the OpenAI-compatible client
├── Web/                         WKWebView bridge and the injected window.spotcat runtime
└── Settings/                    settings window, store, shortcut recorder
Resources/                       Info.plist, icons, chat page
extensions/                      built-in extensions (MIT)
scripts/                         bundle, release, icons, release secrets
```

## Releasing

Maintainers release with one command:

```bash
./scripts/new-version.sh 0.3.0        # or 0.3.0-beta.1 for a pre-release
```

It bumps the version in `Resources/Info.plist`, commits, tags `v0.3.0` and pushes.
[`release.yml`](.github/workflows/release.yml) then builds a universal binary, signs it with the
Developer ID certificate, notarizes and staples the app and DMG, and publishes a GitHub Release
with the DMG, ZIP and SHA-256 checksums. The same steps run locally with `make release`. Signing secrets are configured
once with [`scripts/setup-release-secrets.sh`](scripts/setup-release-secrets.sh).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Please report
security problems privately as described in [SECURITY.md](SECURITY.md).

## License

Spotcat is licensed under [AGPL-3.0](LICENSE) © 2026 ThinkAny, LLC. A commercial license without
the AGPL's copyleft obligations is available — contact support@thinkany.ai.

The built-in extensions, extension docs and `spotcat.d.ts` in [`extensions/`](extensions) are
[MIT-licensed](extensions/LICENSE), so third-party extensions can use them under any license.
