# 编码小助手（codec）

URL、Base64 的编码与解码。

| 功能 | 关键词 | 内容匹配 |
|---|---|---|
| URL encode (编码) | `url encode`、`编码` | — |
| URL decode (解码) | `url decode`、`解码` | 含 `%XX` 转义 |
| Base64 encode (编码) | `base64`、`编码` | — |
| Base64 decode (解码) | `base64 decode`、`解码` | 形如 Base64 且大小写、数字/符号混合 |

## 文件

```
codec/
├── manifest.json   功能与触发规则（文案用 __MSG_key__ 引用 locales）
├── locales/        zh-Hans.json、en.json
├── index.html      页面结构
├── style.css       样式（透明背景 + 深色模式）
└── main.js         编解码逻辑，使用 spotcat.onEnter / i18n / copyText / hideWindow / chat.open
```

结果区的「追问 AI」会带着输入和结果进入 Spotcat 的 AI 对话。

## 快捷键

- `⌘↩` 复制结果并关闭
- `Esc` 返回搜索
