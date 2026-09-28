# 翻译（translate）

多服务对照翻译，参考 Easydict / uTools 翻译的交互。

- 任意文本都会出现在「匹配推荐」里，↩ 进入即翻译；也可以输入关键词 `翻译` / `fy` / `translate` 进入
- 自动识别源语言：中文 → 英语，其他 → 简体中文；也可以手动指定
- 每个服务一张卡片，可折叠、重试、朗读、复制
- `↩` 立即翻译，`⇧↩` 换行，`⌘↩` 复制第一条结果并关闭

## 翻译服务

| 服务 | 说明 |
|---|---|
| 系统翻译 | macOS 26 Translation 框架，离线、免费；需要在「系统设置 › 通用 › 语言与地区 › 翻译语言」下载语言包 |
| Google 翻译 | 免费接口 `translate.googleapis.com`，无需配置；部分网络环境无法访问 |
| AI 翻译 | 使用 Spotcat 设置中的 AI 服务（`spotcat.ai`，需要 `ai` 权限） |

每条译文都可以点「追问 AI」，带着原文和译文进入 Spotcat 的 AI 对话继续提问。

服务开关、目标语言等设置（语言栏右侧按钮）保存在 `spotcat.storage`。界面支持简体中文和英文（`locales/`），语言名称由 `Intl.DisplayNames` 按界面语言生成。

## 文件

```
translate/
├── manifest.json   声明 network、ai 权限；text 规则让任意文本都能触发
├── locales/        zh-Hans.json、en.json
├── index.html
├── style.css
├── languages.js    语言表及各服务的语言代码映射
├── services.js     翻译服务定义（新增服务只需在 SERVICES 里加一项）
└── main.js         页面逻辑
```

## 用到的 Spotcat API

`onEnter`、`i18n`、`detectLanguage`、`translate`、`fetch`、`ai`、`chat.open`、`speak` / `stopSpeaking`、`copyText`、`hideWindow`、`storage`、`openURL`、`openSettings`
