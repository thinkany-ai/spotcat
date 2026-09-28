<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Spotcat">
</p>

<h1 align="center">Spotcat</h1>

<p align="center">
  <strong>快速、原生的 macOS 启动器 —— 应用、文件、网页、扩展和 AI，一个输入框搞定。</strong>
</p>

<p align="center">
  <a href="https://github.com/thinkany-ai/spotcat/releases"><img src="https://img.shields.io/github/v/release/thinkany-ai/spotcat?include_prereleases&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <a href="https://github.com/thinkany-ai/spotcat/actions/workflows/ci.yml"><img src="https://github.com/thinkany-ai/spotcat/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

---

按 **⌥Space**，输入，按 **↩**。Spotcat 是用 Swift + AppKit 编写的 Spotlight / Raycast 风格启动器：
搜索面板是原生的，快而轻；扩展是普通的 HTML/JS，任何人都能写。

## 功能

- **应用**：模糊搜索，支持词首和缩写匹配（`vsc` → Visual Studio Code）、中文拼音（`wyy` → 网易云音乐），常用应用自动靠前。
- **文件**：`file: report` 通过 Spotlight 索引搜索用户目录，按目录分组；支持通配符（`file: *.dmg`、`douchat*.dmg`）和路径浏览 + Tab 补全（`file: ~/Down` ⇥）。输入像文件名的内容时会推荐文件搜索。
- **网页**：直接输入网址（`github.com`、`localhost:3000`）打开；快捷链接如 `gh spotcat`、`g 天气`；任意文字都可以用默认搜索引擎搜索。
- **AI 对话**：在搜索框直接提问，或从扩展的结果带着上下文继续追问。流式输出、Markdown 渲染，支持任意 OpenAI 兼容接口（使用你自己的 Key）。
- **扩展**：HTML/CSS/JS 编写，可通过关键词或内容（正则）触发。内置 URL/Base64 编解码和多服务对照翻译（系统翻译、Google、AI）。
- **原生体验**：不抢焦点的浮动面板、全局快捷键、浅色/深色、简体中文/English、开机启动、可拖动并记住位置。

## 安装

从 [Releases](https://github.com/thinkany-ai/spotcat/releases) 下载最新的 `Spotcat-x.y.z.dmg`，打开后把 **Spotcat**
拖到「应用程序」。安装包为通用二进制（Apple 芯片 + Intel），使用 Developer ID 签名并经过 Apple 公证。

需要 **macOS 13 Ventura** 及以上；系统翻译需要 macOS 26。

## 使用

| 按键 | 作用 |
|---|---|
| **⌥Space** | 呼出 / 隐藏 Spotcat（可在设置中修改） |
| **↑ ↓ ← →** | 移动选中项 |
| **↩** | 打开 / 执行选中项 |
| **⌘↩** | 在访达中显示选中的应用或文件 |
| **⇥** | 补全路径，或在文件搜索中切换目录 |
| **Esc** | 清空输入、退出扩展或对话，再按一次隐藏 |
| **⌘,** | 设置 |

| 输入 | 结果 |
|---|---|
| `cal` | 应用、扩展和指令 |
| `file: 发票` · `file: *.pdf` · `file: ~/Downloads/` | 文件搜索 / 路径浏览 |
| `github.com` · `gh spotcat` · `bd 天气` | 打开网址或快捷链接 |
| `%E4%BD%A0` · `SGVsbG8=` · 任意文字 | 匹配推荐：解码、翻译、AI 对话、网页搜索 |
| `设置` / `settings` | 打开 Spotcat 设置 |

**AI**：在「设置 › AI」中填写服务商、Base URL、API Key 和模型。Key 保存在本机
`~/Library/Application Support/Spotcat/ai.json`（权限 600），只会发送给你配置的服务商。

## 扩展

扩展就是一个包含 `manifest.json` 和 `index.html` 的目录：

```
my-extension/
├── manifest.json   功能、关键词、内容匹配规则、权限
├── index.html      进入功能后显示的页面（运行在 WKWebView 中）
├── locales/        可选，多语言文案（en.json、zh-Hans.json …）
└── main.js / style.css
```

页面通过 `window.spotcat` 与 Spotcat 交互：剪贴板、存储、不受 CORS 限制的 `fetch`（`network` 权限）、语言识别、
系统翻译、朗读、用户配置的 AI（`ai` 权限），以及用 `spotcat.chat.open()` 把结果交给内置 AI 对话继续追问。

把扩展放到 `~/Library/Application Support/Spotcat/Extensions/`（可以用软链接），在「设置 › 扩展」中重新加载即可。
完整的清单字段和 API 见 **[extensions/README.md](extensions/README.md)**，类型声明见 [`extensions/spotcat.d.ts`](extensions/spotcat.d.ts)。

## 从源码构建

需要 macOS 13+、Swift 5.9+（Xcode 或 Command Line Tools），编译系统翻译相关代码需要 **macOS 26 SDK**。

```bash
git clone https://github.com/thinkany-ai/spotcat.git
cd spotcat
make run          # 编译 → build/Spotcat Dev.app（ad-hoc 签名）→ 启动
```

| 命令 | 作用 |
|---|---|
| `make build` / `make debug` | 为本机构建 `build/Spotcat Dev.app` |
| `make universal` | 构建通用二进制（arm64 + x86_64） |
| `make release` | 签名、公证并打包 DMG + ZIP 到 `dist/`（维护者） |
| `make icons` | 从 `Resources/Icon/*.svg` 重新生成图标（需要 `brew install librsvg`） |
| `SPOTCAT_CHANNEL=release make build` | 在本地构建正式版 `build/Spotcat.app`（未签名） |

本地构建的是**开发版 Spotcat Dev**：独立的 Bundle ID（`ai.thinkany.spotcat.dev`）、数据目录（`~/Library/Application Support/Spotcat Dev`）、
默认快捷键（⌥⇧Space）、琥珀色图标和面板上的 DEV 标签，开发调试不会影响已安装的正式版，两者可以同时运行。`make release`（以及 CI）构建的是正式版 **Spotcat**。

只安装了 Command Line Tools 时没有 SwiftUI 宏插件，请用 `ObservableObject` 代替 `@State` / `@Observable`。

## 发布

维护者一条命令发布新版本：

```bash
./scripts/new-version.sh 0.3.0        # 预发布用 0.3.0-beta.1
```

它会修改 `Resources/Info.plist` 的版本号、提交、打 `v0.3.0` 标签并推送。随后 [`release.yml`](.github/workflows/release.yml)
构建通用二进制、用 Developer ID 证书签名、公证并 staple App 与 DMG，发布 GitHub Release（附 DMG、ZIP 和 SHA-256 校验）。本地用 `make release` 执行同样的流程。签名凭据用
[`scripts/setup-release-secrets.sh`](scripts/setup-release-secrets.sh) 一次性设置到仓库 Secrets。

## 参与贡献

欢迎提交 Issue 和 Pull Request，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

Spotcat 以 [AGPL-3.0](LICENSE) 授权 © 2026 ThinkAny, LLC。如需不受 AGPL copyleft 约束的商业授权，请联系 support@thinkany.ai。

[`extensions/`](extensions) 中的内置扩展、扩展文档和 `spotcat.d.ts` 采用 [MIT 协议](extensions/LICENSE)，第三方扩展可以按任意协议使用。
