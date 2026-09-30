# Spotcat 扩展开发

扩展就是一个目录：`manifest.json` 描述它提供哪些**功能**以及如何被触发，`index.html` 是进入功能后显示的页面（运行在 WKWebView 中）。纯 HTML/CSS/JS，不需要 Swift；React/Vue 等框架打包成静态文件同样可用。

本目录下的每个子目录都是一个独立扩展，构建 App 时作为内置扩展打包进去。内置扩展和第三方扩展使用完全相同的格式和 API。

| 扩展 | 说明 |
|---|---|
| [`codec`](codec) | URL / Base64 编码解码 |
| [`translate`](translate) | 多服务对照翻译 |

## 目录结构

```
my-extension/
├── manifest.json   必需：扩展信息、功能、触发规则、权限
├── index.html      必需（可用 main 字段改名）：进入功能后的页面
├── style.css       可选，页面里用相对路径引用
├── main.js         可选
├── icon.png        可选，也可用 "sf:<SF Symbol>" 图标
├── locales/        可选：多语言文案，如 zh-Hans.json、en.json
└── README.md       建议：说明功能、关键词、用到的 API
```

在 JS 顶部加 `/// <reference path="../spotcat.d.ts" />` 可获得 API 补全（见 [`spotcat.d.ts`](spotcat.d.ts)）。

页面请用普通 `<script src>` 加载脚本：扩展页面以 `file://` 打开，ES Module（`type="module"`）可能被拦截。

## 安装 / 开发

把扩展目录放到（或软链接到）：

```
~/Library/Application Support/Spotcat/Extensions/<你的扩展>/        # 正式版
~/Library/Application Support/Spotcat Dev/Extensions/<你的扩展>/    # 本地构建的开发版
```

```sh
ln -s "$PWD/my-extension" ~/Library/Application\ Support/Spotcat/Extensions/my-extension
```

每次呼出 Spotcat 时会重新读取 manifest（间隔 5 秒以上），改完直接再呼出即可生效。页面每次进入功能都会重新加载。

扩展 `id` 不能与内置扩展重复，重复的会被忽略。

在「设置 › 扩展」中可以查看已安装的扩展、启用或禁用整个扩展或单个功能，也有「重新加载」按钮。

## manifest.json

```json
{
  "id": "codec",
  "name": "编码小助手",
  "version": "0.1.0",
  "description": "URL、Base64 编码与解码",
  "author": "Spotcat",
  "icon": "sf:chevron.left.forwardslash.chevron.right",
  "iconColor": "#3B82F6",
  "main": "index.html",
  "features": [
    {
      "code": "url-decode",
      "title": "URL decode (解码)",
      "keywords": ["url decode", "url 解码", "解码"],
      "matches": [
        { "type": "regex", "pattern": "%[0-9A-Fa-f]{2}", "minLength": 3 }
      ]
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `id` | 唯一标识，建议小写加连字符 |
| `name` | 扩展名，显示在进入后的面包屑里 |
| `icon` | `sf:<SF Symbol 名>`（渲染为彩色圆角方块），或相对扩展目录的图片路径（png / icns / pdf） |
| `iconColor` | `sf:` 图标的背景色，默认系统蓝 |
| `main` | 入口页面，默认 `index.html` |
| `permissions` | 需要的敏感能力：`"network"`（`spotcat.fetch`）、`"ai"`（`spotcat.ai`，消耗用户的 AI 额度） |
| `defaultLocale` | 默认语言，如 `"zh-Hans"`；当前语言缺失的文案从这里取 |
| `features[]` | 功能列表，每个功能是搜索结果里的一个格子 |

### 功能（feature）

| 字段 | 说明 |
|---|---|
| `code` | 功能标识，进入时传给页面 |
| `title` | 格子上的名称；参与关键词搜索 |
| `icon` / `iconColor` | 可选，覆盖扩展图标 |
| `keywords` | 关键词。输入模糊命中时出现在 **最佳搜索结果**，中文自动支持拼音 |
| `matches` | 内容匹配规则，任一命中时出现在 **匹配推荐** |

### 匹配规则（matches）

| `type` | 说明 |
|---|---|
| `regex` | `pattern` 为 NSRegularExpression 正则，对去掉首尾空白的输入做搜索（需要全文匹配请自己加 `^…$`） |
| `text` | 任意文本，只看长度 |

两种规则都支持 `minLength`（默认 1）和 `maxLength`。

规则写得太宽会让「匹配推荐」变得嘈杂。例如 Base64 规则如果只写 `^[A-Za-z0-9+/=]+$`，输入 `calendar` 也会被推荐解码。

## 多语言

扩展的界面语言跟随 Spotcat 设置（跟随系统 / 简体中文 / English）。

**文案文件**：`locales/<语言>.json`，扁平的 key → 文案，`{name}` 为占位符：

```json
{ "name": "翻译", "featureTitle": "翻译", "detected": "识别为 {lang}" }
```

**manifest**：`name`、`description`、功能的 `title` / `description` / `keywords` 可写成 `"__MSG_<key>__"`。
关键词会展开为**所有语言**的文案，所以中文界面下输入英文关键词也能搜到。

**选语言**：完全匹配 → 同语种（如 `zh-Hant` 用 `zh-Hans`）→ `en` → `defaultLocale`；缺失的 key 用 `defaultLocale` 补。

**页面**：

```html
<button data-i18n="copy"></button>
<textarea data-i18n-placeholder="inputPlaceholder"></textarea>
<button data-i18n-title="settings"></button>
```

```js
const { t, locale } = spotcat.i18n;
t('detected', { lang: '英语' });           // "识别为 英语"
new Intl.DisplayNames([locale], { type: 'language' }).of('ja'); // 语言名等可直接用 Intl
```

`data-i18n*` 在页面加载时自动填充；动态插入的元素调用 `spotcat.i18n.apply(el)`。

## AI 与对话

AI 服务在 Spotcat 设置中统一配置（任意 OpenAI 兼容接口），扩展无需自己管理 API Key。

**调用模型**（需要 `"permissions": ["ai"]`）：

```js
const { configured, model } = await spotcat.ai.info();

// 一次性返回
const text = await spotcat.ai.chat({ messages: [{ role: 'user', content: 'hi' }] });

// 流式 + 可中止
const controller = new AbortController();
await spotcat.ai.chat({ messages, onDelta: (d) => (out.textContent += d), signal: controller.signal });
```

**进入内置 AI 对话**（无需权限）：把扩展里的结果作为上下文，交给 Spotcat 的对话面板继续追问。对话中按 Esc 或返回按钮回到扩展，扩展状态保留。

```js
spotcat.chat.open({
  title: '翻译：hello world',
  context: [
    { title: '原文（英语）', content: 'hello world' },
    { title: 'Google 译文（简体中文）', content: '你好世界' },
  ],
  prompt: '',   // 可选：预填输入框
  send: false,  // 可选：true 时直接发送 prompt
});
```

上下文会拼进系统提示发给模型，并在对话顶部以可折叠卡片显示。

## 页面 API：`window.spotcat`

页面加载前注入，无需引入任何脚本。所有方法返回 Promise，失败时 reject。完整类型见 [`spotcat.d.ts`](spotcat.d.ts)。

```js
// 进入功能时回调（页面加载后立即触发一次）
spotcat.onEnter(({ code, type, payload }) => {
  // type: 'keyword'（关键词进入，payload 是输入的关键词）
  //       'match'  （内容匹配进入，payload 是匹配到的内容）
});
```

| API | 说明 | 权限 |
|---|---|---|
| `copyText(text)` | 复制到剪贴板 | |
| `hideWindow()` | 隐藏窗口，扩展保持打开（90 秒内再呼出回到扩展） | |
| `exit()` | 退出扩展，回到搜索 | |
| `openURL(url)` | 打开 `http(s)` 网页或 `x-apple.systempreferences:` 设置页 | |
| `openSettings(tab?)` | 打开 Spotcat 设置窗口，`tab` 可为 `general` / `profile` / `ai` / `about` | |
| `fetch(url, { method, headers, body, timeout })` | 由 App 代发请求，不受 CORS 限制；返回 `{ status, headers, body }` | `network` |
| `detectLanguage(text)` | 识别语言，返回 `'en'`、`'zh-Hans'` 等，或 `null` | |
| `translate({ text, from, to })` | 系统离线翻译（macOS 26+，需下载语言包），返回 `{ text, from, to }` | |
| `speak(text, lang?)` / `stopSpeaking()` | 系统语音朗读 | |
| `storage.get(key)` / `set(key, value)` / `remove(key)` | 扩展私有的持久化存储（JSON） | |
| `i18n.locale` / `i18n.t(key, vars)` / `i18n.apply(root)` | 多语言，见上文 | |
| `ai.info({ model })` / `ai.chat({ messages, model, onDelta, signal })` | 使用 Spotcat 配置的 AI 服务；`model` 可选，默认用设置里的默认模型 | `ai` |
| `chat.open({ title, context, prompt, send })` | 带上下文进入内置 AI 对话 | |

`storage` 数据存放在 `~/Library/Application Support/Spotcat/ExtensionData/<扩展 id>.json`。

## 页面约定

- 背景保持透明（`background: transparent`），让面板的毛玻璃透出来
- 用 `@media (prefers-color-scheme: dark)` 适配深色模式
- `Esc` 由 Spotcat 处理（退出扩展），页面收不到
- ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z 在输入框中可用
- 页面内 `http(s)` 链接会在默认浏览器打开
- 页面只能读取自己扩展目录下的文件
- 页面自身的 `fetch`/XHR 受浏览器 CORS 限制（页面源为 `file://`），访问第三方接口请用 `spotcat.fetch`

