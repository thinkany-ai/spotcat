import Foundation

enum LocaleResolver {
    /// "zh-Hans-CN" -> "zh-Hans"，"zh-TW" -> "zh-Hant"，"en-US" -> "en"
    static func normalize(_ identifier: String) -> String {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased() else { return "en" }
        if language == "zh" {
            let traditional = parts.dropFirst().contains { ["Hant", "TW", "HK", "MO"].contains($0) }
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        return language
    }

    /// 用户偏好的语言：设置里指定的，或系统首选语言
    static var preferred: String {
        let setting = SettingsStore.shared.language
        if setting != SettingsStore.followSystem { return setting }
        return normalize(Locale.preferredLanguages.first ?? "en")
    }

    /// 在可用语言里选最合适的：完全匹配 → 同一语种 → 英语 → 默认语言
    static func best(among available: [String], defaultLocale: String) -> String {
        let preferred = preferred
        if available.contains(preferred) { return preferred }
        let language = preferred.split(separator: "-").first.map(String.init) ?? preferred
        if let sameLanguage = available.first(where: { $0.hasPrefix(language) }) { return sameLanguage }
        if available.contains("en") { return "en" }
        return defaultLocale
    }
}

/// 目录下 locales/<语言>.json 形式的翻译表，扩展和内置聊天面板共用
struct LocaleMessages {
    let locale: String
    /// 当前语言的文案，缺失的 key 用默认语言补齐
    let messages: [String: String]
    /// 所有语言的文案，用于关键词等需要合并各语言的场景
    let all: [String: [String: String]]

    init(directory: URL, defaultLocale: String) {
        var all: [String: [String: String]] = [:]
        let localesDir = directory.appendingPathComponent("locales", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: localesDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                all[file.deletingPathExtension().lastPathComponent] = dict
            }
        }
        self.all = all
        locale = all.isEmpty ? defaultLocale : LocaleResolver.best(among: Array(all.keys), defaultLocale: defaultLocale)
        messages = (all[defaultLocale] ?? [:]).merging(all[locale] ?? [:]) { _, current in current }
    }

    /// "__MSG_key__" 形式的字符串替换为当前语言的文案，其他原样返回
    func resolve(_ text: String) -> String {
        guard let key = Self.messageKey(text) else { return text }
        return messages[key] ?? text
    }

    /// 关键词：占位符展开为所有语言的文案
    func resolveAll(_ text: String) -> [String] {
        guard let key = Self.messageKey(text) else { return [text] }
        var seen = Set<String>()
        return all.values.compactMap { $0[key] }.filter { seen.insert($0).inserted }
    }

    private static func messageKey(_ text: String) -> String? {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return nil }
        return String(text.dropFirst(6).dropLast(2))
    }
}

/// App 自身界面文案（简体中文 / English）
enum L10n {
    static var language: String {
        LocaleResolver.best(among: ["zh-Hans", "en"], defaultLocale: "en")
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let table = language == "zh-Hans" ? zhHans : en
        let format = table[key] ?? en[key] ?? key
        return args.isEmpty ? format : String(format: format, arguments: args)
    }

    private static let zhHans: [String: String] = [
        "search.placeholder": "搜索或提问…",
        "section.recent": "最近使用",
        "section.best": "最佳搜索结果",
        "section.matches": "匹配推荐",
        "section.files": "文件",
        "chat.itemTitle": "AI 对话",
        "chat.model.manage": "管理模型…",
        "chat.model.noKey": "未填写 API Key",
        "command.settings": "Spotcat 设置",
        "command.searchFiles": "搜索文件",
        "web.open": "打开 %@",
        "files.searchFor": "搜索文件：%@",
        "files.all": "全部 %d",
        "files.showAll": "显示全部 %d 个",
        "files.browse": "浏览 %@",
        "web.search": "%@：%@",
        "web.searchWith": "%@ 搜索",
        "settings.tab.quicklinks": "快捷链接",
        "quicklinks.name": "名称",
        "quicklinks.keyword": "关键词",
        "quicklinks.url": "网址",
        "quicklinks.add": "添加",
        "quicklinks.reset": "恢复默认",
        "quicklinks.searchEngine": "默认搜索引擎",
        "quicklinks.none": "不显示",
        "quicklinks.edit": "编辑",
        "quicklinks.delete": "删除",
        "quicklinks.done": "完成",
        "quicklinks.untitled": "未命名",
        "quicklinks.footer": "在 Spotcat 中输入「关键词 内容」打开网址，{query} 会替换为内容，如 gh spotcat；只输入关键词则打开网站首页。双击一行也可以编辑。",
        "quicklinks.searchEngineFooter": "输入任意文字时，匹配推荐中会出现「用 … 搜索」。可选网址中包含 {query} 的快捷链接。",
        "files.searching": "搜索中…",
        "files.empty": "没有找到匹配的文件",
        "files.detail": "%d 个结果 · ⇥ 切换目录 · ↩ 打开 · ⌘↩ 在访达中显示",
        "files.shortcuts": "↩ 打开 · ⌘↩ 在访达中显示",
        "files.pathDetail": "%d 项 · ⇥ 补全 · ↩ 打开 · ⌘↩ 在访达中显示",
        "files.missingDirectory": "目录不存在或无法访问",
        "files.noEntries": "没有匹配的条目",
        "files.hint": "输入文件名搜索，如 file: report、file: *.dmg；或输入路径浏览，如 file: ~/Downloads/",

        "menu.open": "打开 Spotcat（%@）",
        "menu.settings": "设置…",
        "menu.resetPosition": "重置窗口位置",
        "menu.quit": "退出 Spotcat",
        "menu.edit": "编辑",
        "menu.undo": "撤销",
        "menu.redo": "重做",
        "menu.cut": "剪切",
        "menu.copy": "拷贝",
        "menu.paste": "粘贴",
        "menu.selectAll": "全选",

        "settings.title": "Spotcat 设置",
        "settings.general": "通用",
        "settings.launchAtLogin": "开机时启动",
        "settings.requiresApproval": "需要在系统设置中允许 Spotcat 作为登录项",
        "settings.openSystemSettings": "打开系统设置",
        "settings.language": "语言",
        "settings.followSystem": "跟随系统",
        "settings.shortcut": "快捷键",
        "settings.shortcut.open": "呼出 Spotcat",
        "settings.shortcut.recording": "请按下快捷键…",
        "settings.shortcut.reset": "恢复默认 %@",
        "settings.shortcut.taken": "%@ 已被其他应用或系统占用，请换一个",
        "settings.shortcut.registerFailed": "%@ 注册失败，可能已被其他应用（如 Raycast/Alfred）占用",
        "settings.shortcut.takenBy": "%@ 已被「%@」占用，请换一个，或先在对应的设置里关闭它",
        "settings.shortcut.allTaken": "候选快捷键都被占用了，请手动设置一个",
        "settings.shortcut.defaultTaken": "%@ 被「%@」占用，暂时使用 %@",
        "settings.shortcut.useDefault": "改用 %@",
        "shortcut.owner.spotlight": "聚焦（Spotlight）",
        "shortcut.owner.finderSearch": "访达搜索窗口",
        "shortcut.owner.inputSource": "切换输入法",
        "shortcut.owner.emoji": "表情与符号",
        "shortcut.owner.system": "系统快捷键",
        "shortcut.prompt.title": "用 %@ 呼出 Spotcat",
        "shortcut.prompt.system": "%@ 目前被「%@」占用。打开「系统设置 › 键盘 › 键盘快捷键」，在对应分类里关掉它，Spotcat 就能用上。",
        "shortcut.prompt.app": "%@ 目前被 %@ 占用。在 %@ 的设置里把它的快捷键改掉或关闭，Spotcat 就能用上。",
        "shortcut.prompt.alsoTaken": "另外 %@。",
        "shortcut.prompt.takenItem": "%@ 被「%@」占用",
        "shortcut.prompt.separator": "，",
        "shortcut.prompt.fallback": "在此之前先用 %@ 呼出 Spotcat；%@ 空出来后会自动切换过去。",
        "shortcut.prompt.openKeyboard": "打开键盘快捷键设置",
        "shortcut.prompt.openApp": "打开 %@",
        "shortcut.prompt.ok": "好",
        "shortcut.prompt.later": "暂时用 %@",
        "shortcut.prompt.dontRemind": "不再提醒",
        "shortcut.prompt.doneTitle": "已切换到 %@",
        "shortcut.prompt.doneMessage": "现在按 %@ 就能呼出 Spotcat。",

        "settings.tab.general": "通用",
        "settings.tab.extensions": "扩展",
        "extensions.builtIn": "内置",
        "extensions.local": "本地",
        "extensions.author": "作者：%@",
        "extensions.features": "%d 个功能",
        "extensions.keywords": "关键词：%@",
        "extensions.matches": "内容匹配",
        "extensions.permission.network": "网络",
        "extensions.permission.ai": "AI",
        "extensions.permissions": "权限：%@",
        "extensions.listSeparator": "、",
        "extensions.openFolder": "打开第三方扩展目录",
        "extensions.reveal": "在访达中显示",
        "extensions.reload": "重新加载",
        "extensions.empty": "没有找到扩展",
        "extensions.footer": "内置扩展随 App 一起安装，位于 App 包内。第三方扩展放进「第三方扩展目录」后点「重新加载」即可出现在这里。禁用后不会出现在搜索结果中。",
        "settings.tab.profile": "个人资料",
        "settings.tab.ai": "模型",
        "settings.tab.about": "关于",
        "settings.appearance": "外观",
        "settings.appearance.light": "浅色",
        "settings.appearance.dark": "深色",
        "settings.window": "窗口",
        "settings.section.appearance": "外观与语言",
        "settings.section.startup": "启动",
        "settings.profile.cardTitle": "设置你的资料",
        "settings.profile.cardSubtitle": "头像与昵称",
        "settings.results": "搜索结果",
        "settings.results.recents": "显示「最近使用」",
        "settings.results.suggestions": "显示「匹配推荐」",
        "settings.results.history": "使用记录",
        "settings.results.historyHelp": "用于「最近使用」和按使用频率排序",
        "settings.results.clear": "清除",
        "settings.resetPosition": "重置窗口位置",
        "settings.resetPosition.help": "让搜索面板回到屏幕中上方",
        "settings.reset": "重置",
        "settings.profile.avatar": "头像",
        "settings.profile.chooseAvatar": "选择图片…",
        "settings.profile.removeAvatar": "移除",
        "settings.profile.nickname": "昵称",
        "settings.profile.nicknamePlaceholder": "希望怎么称呼你",
        "settings.profile.footer": "昵称会用于 AI 对话中的称呼。资料只保存在本机。",
        "about.description": "macOS 启动器：搜索应用、运行扩展、与 AI 对话。",
        "about.version": "版本 %@（%@）",
        "about.folders": "文件夹",
        "about.extensionsFolder": "第三方扩展目录",
        "about.dataFolder": "数据目录",
        "about.showInFinder": "在访达中显示",
        "about.links": "链接",
        "about.website": "官网",
        "about.source": "源代码",
        "about.feedback": "问题反馈",
        "about.feedbackHelp": "在 GitHub 上提交问题或建议",
        "about.changelog": "更新日志",
        "about.open": "打开",
        "update.section": "软件更新",
        "update.title": "检查更新",
        "update.check": "检查更新",
        "update.checking": "正在检查更新…",
        "update.upToDate": "已是最新版本",
        "update.available": "发现新版本 %@",
        "update.install": "更新到 %@ 并重启",
        "update.downloading": "正在下载更新… %d%%",
        "update.installing": "正在安装并重启…",
        "update.failed": "更新失败：%@",
        "update.disabled": "开发版不检查更新",
        "update.idle": "当前版本 %@",
        "update.auto": "自动检查更新",
        "update.releaseNotes": "查看更新说明",
        "update.menu": "更新到 %@…",
        "update.error.service": "无法访问更新服务（HTTP %d）",
        "update.error.archive": "更新包无法解压",
        "update.error.identity": "更新包不是 Spotcat",
        "update.error.unsigned": "当前版本未使用开发者证书签名，无法自动更新，请手动下载",
        "update.error.signature": "更新包签名校验失败",
        "update.error.checksum": "更新包校验失败，请重试",
        "update.error.permission": "没有权限替换当前 App，请手动下载安装",

        "models.default": "默认模型",
        "models.noProviders": "请先添加服务商",
        "models.byokHint": "AI 对话和扩展（如翻译）使用默认模型。自带 Key（BYOK）：Key 只保存在本机，只会发送给对应的服务商。",
        "models.providers": "服务商",
        "models.empty": "还没有服务商，点击「添加服务商」开始配置。",
        "models.addProvider": "添加服务商",
        "models.kind.anthropic": "Anthropic",
        "models.kind.openai": "OpenAI 兼容",
        "models.noKey": "未填 Key",
        "models.count": "%d 个模型",
        "models.form.preset": "预设",
        "models.form.kind": "接口格式",
        "models.form.name": "名称",
        "models.form.namePlaceholder": "如 DeepSeek",
        "models.form.models": "模型",
        "models.form.endpoint": "请求地址：%@",
        "models.preset.custom": "自定义",
        "models.test.run": "测试连接",
        "models.test.passed": "连接成功 · %@",
        "models.test.noModel": "请至少填写一个模型",
        "extension.exit": "退出扩展（Esc）",
        "extension.detach": "分离为独立窗口",
        "extension.pin": "窗口置顶",
        "extension.unpin": "取消置顶",

        "error.ai.notConfigured": "尚未配置模型，请在「设置 › 模型」中添加服务商和 API Key",
        "error.permission": "扩展未声明 %@ 权限",
        "error.translate.missingPack": "未下载「%@ → %@」语言包：系统设置 › 通用 › 语言与地区 › 翻译语言",
        "error.translate.unsupported": "系统翻译不支持该语言组合",
        "error.translate.requiresOS": "系统翻译需要 macOS 26 及以上",
        "error.translate.unknownSource": "无法识别源语言",
    ]

    private static let en: [String: String] = [
        "search.placeholder": "Search or ask…",
        "section.recent": "Recent",
        "section.best": "Best Matches",
        "section.matches": "Suggestions",
        "section.files": "Files",
        "chat.itemTitle": "Ask AI",
        "chat.model.manage": "Manage Models…",
        "chat.model.noKey": "No API key",
        "command.settings": "Spotcat Settings",
        "command.searchFiles": "Search Files",
        "web.open": "Open %@",
        "files.searchFor": "Search files: %@",
        "files.all": "All %d",
        "files.showAll": "Show all %d",
        "files.browse": "Browse %@",
        "web.search": "%@: %@",
        "web.searchWith": "Search %@",
        "settings.tab.quicklinks": "Quicklinks",
        "quicklinks.name": "Name",
        "quicklinks.keyword": "Keyword",
        "quicklinks.url": "URL",
        "quicklinks.add": "Add",
        "quicklinks.reset": "Restore Defaults",
        "quicklinks.searchEngine": "Default search engine",
        "quicklinks.none": "None",
        "quicklinks.edit": "Edit",
        "quicklinks.delete": "Delete",
        "quicklinks.done": "Done",
        "quicklinks.untitled": "Untitled",
        "quicklinks.footer": "In Spotcat, type \"keyword text\" to open the URL with {query} replaced, e.g. gh spotcat. The keyword alone opens the site's home page. Double-click a row to edit it.",
        "quicklinks.searchEngineFooter": "Suggested as \"Search …\" for any text you type. Any quicklink whose URL contains {query} can be used.",
        "files.searching": "Searching…",
        "files.empty": "No matching files",
        "files.detail": "%d results · ⇥ switch folder · ↩ open · ⌘↩ reveal in Finder",
        "files.shortcuts": "↩ open · ⌘↩ reveal in Finder",
        "files.pathDetail": "%d items · ⇥ complete · ↩ open · ⌘↩ reveal in Finder",
        "files.missingDirectory": "Folder doesn't exist or can't be read",
        "files.noEntries": "No matching items",
        "files.hint": "Type a file name, e.g. file: report or file: *.dmg — or a path, e.g. file: ~/Downloads/",

        "menu.open": "Open Spotcat (%@)",
        "menu.settings": "Settings…",
        "menu.resetPosition": "Reset Window Position",
        "menu.quit": "Quit Spotcat",
        "menu.edit": "Edit",
        "menu.undo": "Undo",
        "menu.redo": "Redo",
        "menu.cut": "Cut",
        "menu.copy": "Copy",
        "menu.paste": "Paste",
        "menu.selectAll": "Select All",

        "settings.title": "Spotcat Settings",
        "settings.general": "General",
        "settings.launchAtLogin": "Launch at login",
        "settings.requiresApproval": "Allow Spotcat as a login item in System Settings",
        "settings.openSystemSettings": "Open System Settings",
        "settings.language": "Language",
        "settings.followSystem": "System",
        "settings.shortcut": "Shortcut",
        "settings.shortcut.open": "Open Spotcat",
        "settings.shortcut.recording": "Press shortcut…",
        "settings.shortcut.reset": "Reset to %@",
        "settings.shortcut.taken": "%@ is already used by another app or the system",
        "settings.shortcut.registerFailed": "Failed to register %@; it may be used by another app (e.g. Raycast/Alfred)",
        "settings.shortcut.takenBy": "%@ is used by %@. Pick another one, or turn it off there first",
        "settings.shortcut.allTaken": "All default shortcuts are taken; please record one",
        "settings.shortcut.defaultTaken": "%@ is used by %@; using %@ for now",
        "settings.shortcut.useDefault": "Use %@",
        "shortcut.owner.spotlight": "Spotlight",
        "shortcut.owner.finderSearch": "Finder search window",
        "shortcut.owner.inputSource": "Input Sources",
        "shortcut.owner.emoji": "Emoji & Symbols",
        "shortcut.owner.system": "a system shortcut",
        "shortcut.prompt.title": "Open Spotcat with %@",
        "shortcut.prompt.system": "%@ is currently used by %@. Open System Settings › Keyboard › Keyboard Shortcuts and turn it off there so Spotcat can use it.",
        "shortcut.prompt.app": "%@ is currently used by %@. Change or turn off that shortcut in %@'s settings so Spotcat can use it.",
        "shortcut.prompt.alsoTaken": "Also, %@.",
        "shortcut.prompt.takenItem": "%@ is used by %@",
        "shortcut.prompt.separator": "; ",
        "shortcut.prompt.fallback": "Until then, Spotcat opens with %@ and switches to %@ automatically once it is free.",
        "shortcut.prompt.openKeyboard": "Open Keyboard Shortcuts",
        "shortcut.prompt.openApp": "Open %@",
        "shortcut.prompt.ok": "OK",
        "shortcut.prompt.later": "Use %@ for Now",
        "shortcut.prompt.dontRemind": "Don't remind me again",
        "shortcut.prompt.doneTitle": "Now using %@",
        "shortcut.prompt.doneMessage": "Press %@ to open Spotcat.",

        "settings.tab.general": "General",
        "settings.tab.extensions": "Extensions",
        "extensions.builtIn": "Built-in",
        "extensions.local": "Local",
        "extensions.author": "By %@",
        "extensions.features": "%d commands",
        "extensions.keywords": "Keywords: %@",
        "extensions.matches": "Content match",
        "extensions.permission.network": "Network",
        "extensions.permission.ai": "AI",
        "extensions.permissions": "Permissions: %@",
        "extensions.listSeparator": ", ",
        "extensions.openFolder": "Open Third-Party Extensions Folder",
        "extensions.reveal": "Show in Finder",
        "extensions.reload": "Reload",
        "extensions.empty": "No extensions found",
        "extensions.footer": "Built-in extensions ship inside the app. Put third-party extensions in the third-party extensions folder and click Reload. Disabled items won't appear in search.",
        "settings.tab.profile": "Profile",
        "settings.tab.ai": "Models",
        "settings.tab.about": "About",
        "settings.appearance": "Appearance",
        "settings.appearance.light": "Light",
        "settings.appearance.dark": "Dark",
        "settings.window": "Window",
        "settings.section.appearance": "Appearance & Language",
        "settings.section.startup": "Startup",
        "settings.profile.cardTitle": "Set up your profile",
        "settings.profile.cardSubtitle": "Avatar & nickname",
        "settings.results": "Search Results",
        "settings.results.recents": "Show \"Recent\"",
        "settings.results.suggestions": "Show \"Suggestions\"",
        "settings.results.history": "Usage history",
        "settings.results.historyHelp": "Used for Recent and frequency-based ranking",
        "settings.results.clear": "Clear",
        "settings.resetPosition": "Reset window position",
        "settings.resetPosition.help": "Move the search panel back to the top center of the screen",
        "settings.reset": "Reset",
        "settings.profile.avatar": "Avatar",
        "settings.profile.chooseAvatar": "Choose Image…",
        "settings.profile.removeAvatar": "Remove",
        "settings.profile.nickname": "Nickname",
        "settings.profile.nicknamePlaceholder": "What should we call you?",
        "settings.profile.footer": "Your nickname is used by AI Chat. Profile data stays on this Mac.",
        "about.description": "A launcher for macOS: search apps, run extensions and chat with AI.",
        "about.version": "Version %@ (%@)",
        "about.folders": "Folders",
        "about.extensionsFolder": "Third-party extensions",
        "about.dataFolder": "Data",
        "about.showInFinder": "Show in Finder",
        "about.links": "Links",
        "about.website": "Website",
        "about.source": "Source code",
        "about.feedback": "Feedback",
        "about.feedbackHelp": "Report a problem or suggest an idea on GitHub",
        "about.changelog": "Release notes",
        "about.open": "Open",
        "update.section": "Software Update",
        "update.title": "Check for updates",
        "update.check": "Check for Updates",
        "update.checking": "Checking for updates…",
        "update.upToDate": "You're up to date",
        "update.available": "Version %@ is available",
        "update.install": "Update to %@ and Restart",
        "update.downloading": "Downloading update… %d%%",
        "update.installing": "Installing and restarting…",
        "update.failed": "Update failed: %@",
        "update.disabled": "Updates are disabled in development builds",
        "update.idle": "Current version %@",
        "update.auto": "Check for updates automatically",
        "update.releaseNotes": "Release notes",
        "update.menu": "Update to %@…",
        "update.error.service": "Couldn't reach the update service (HTTP %d)",
        "update.error.archive": "Couldn't unpack the update",
        "update.error.identity": "The download is not Spotcat",
        "update.error.unsigned": "This copy isn't signed with a Developer ID; download the update manually",
        "update.error.signature": "The update's signature couldn't be verified",
        "update.error.checksum": "The download is corrupted; please try again",
        "update.error.permission": "No permission to replace the app; install the update manually",

        "models.default": "Default model",
        "models.noProviders": "Add a provider first",
        "models.byokHint": "AI Chat and extensions such as Translate use the default model. Bring your own key: keys stay on this Mac and are only sent to their provider.",
        "models.providers": "Providers",
        "models.empty": "No providers yet. Click Add Provider to get started.",
        "models.addProvider": "Add Provider",
        "models.kind.anthropic": "Anthropic",
        "models.kind.openai": "OpenAI-compatible",
        "models.noKey": "No key",
        "models.count": "%d models",
        "models.form.preset": "Preset",
        "models.form.kind": "API format",
        "models.form.name": "Name",
        "models.form.namePlaceholder": "e.g. DeepSeek",
        "models.form.models": "Models",
        "models.form.endpoint": "Endpoint: %@",
        "models.preset.custom": "Custom",
        "models.test.run": "Test Connection",
        "models.test.passed": "Connected · %@",
        "models.test.noModel": "Add at least one model",
        "extension.exit": "Exit extension (Esc)",
        "extension.detach": "Open in separate window",
        "extension.pin": "Keep on top",
        "extension.unpin": "Don't keep on top",

        "error.ai.notConfigured": "No model is configured. Add a provider and API key in Settings › Models.",
        "error.permission": "Extension did not declare the %@ permission",
        "error.translate.missingPack": "Language pack \"%@ → %@\" is not downloaded: System Settings › General › Language & Region › Translation Languages",
        "error.translate.unsupported": "This language pair is not supported by system translation",
        "error.translate.requiresOS": "System translation requires macOS 26 or later",
        "error.translate.unknownSource": "Unable to detect the source language",
    ]
}
