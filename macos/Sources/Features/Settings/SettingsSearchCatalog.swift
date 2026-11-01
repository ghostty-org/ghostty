import Foundation

struct SettingsSearchEntry: Identifiable {
    let id: String
    let tab: OhMyGhosttySettingsTab
    let title: String
    let anchor: String
    var keywords: String
    var settingIDs: [String] = []
    var prefixes: [String] = []

    func matches(_ query: String) -> Bool {
        let text = (title + " " + keywords + " " + settingIDs.joined(separator: " "))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        return !tokens.isEmpty && tokens.allSatisfy { text.contains($0) }
    }
}

@MainActor
enum SettingsSearchCatalog {
    static func entries(strings: SettingsStrings) -> [SettingsSearchEntry] {
        let en = SettingsStrings(language: .english)
        let zh = SettingsStrings(language: .simplifiedChinese)
        func item(_ tab: OhMyGhosttySettingsTab, _ title: KeyPath<SettingsStrings, String>,
                  _ prefixes: [String], _ keywords: String = "", anchor: String? = nil) -> SettingsSearchEntry {
            let label = strings[keyPath: title]
            return .init(id: tab.rawValue + ":" + en[keyPath: title], tab: tab, title: label, anchor: anchor ?? label,
                         keywords: en[keyPath: title] + " " + zh[keyPath: title] + " " + en.tabTitle(tab) + " " + zh.tabTitle(tab) + " " + keywords,
                         prefixes: prefixes)
        }
        var result: [SettingsSearchEntry] = [
            item(.general, \.languageSection, ["general.language"], "English 中文 language"),
            item(.general, \.quitSection, ["general.quitWithoutConfirmation"], "exit quit confirmation 退出 确认"),
            item(.terminal, \.sessionRecoverySection, ["sessions.startup"], "startup restore scrollback 启动 恢复 滚屏"),
            .init(id: "terminal:runtime", tab: .terminal, title: strings.runtimeTitle, anchor: strings.runtimeTitle,
                  keywords: "SSH background lifetime deadline TTL Agent completion resume 后台 会话 存活 截止 完成 恢复",
                  prefixes: ["sessions.runtime", "sessions.localRuntime"]),
            item(.controls, \.quickInputSection, ["keyboard.quickInputHeight", "keyboard.quickInputHistory"], "history retention 快捷输入 历史 保留"),
            item(.editor, \.editorOpeningSection, ["editor.fileOpen", "editor.directoryOpen"], "files folders 打开 文件 目录"),
            item(.editor, \.editorBehaviorSection, ["editor.keymap", "editor.autoClose", "editor.wordWrap"], "vim wrap pairs 自动换行 括号"),
            item(.editor, \.editorThemeSection, ["editor.background", "editor.syntax", "editor.theme", "editor.opacity", "editor.blur"], "主题 透明"),
            item(.editor, \.editorTypographySection, ["editor.font", "editor.tabWidth"], "字体 缩进 字号"),
            item(.agents, \.agentIntegrationSection, ["agents.statusHooks"], "hook install cli update agent integration ssh 集成 接入 安装 更新", anchor: "agentIntegrations"),
            item(.agents, \.agentBehaviorSection, ["agents.openQuickInput"], "start complete 开始 完成 快捷输入"),
            item(.agents, \.agentHistorySection, ["agents.history"], "sessions limit 历史 会话 上限"),
            item(.agents, \.notificationsSection, ["notifications."], "notification sound permission 通知 声音 等待"),
            item(.tabs, \.layoutSection, ["tabs.layout", "tabs.sidebar", "tabs.remember"], "vertical horizontal 垂直 水平 侧栏"),
            item(.tabs, \.organizationSection, ["tabs.group", "tabs.order", "tabs.path", "tabs.show"], "group directory order 分组 路径 排序"),
            item(.tabs, \.appearanceTabsSection, ["appearance.tab"], "density icon 行高 图标 密度"),
            item(.tabs, \.resizeRenderingSection, ["terminal.resize"], "resize rendering 调整窗口 渲染"),
            item(.appearance, \.terminalThemeSection, ["appearance.window", "appearance.light", "appearance.dark"], "theme light dark system 主题 深色 浅色 系统"),
            item(.appearance, \.fontSection, ["appearance.font"], "字体 字号 font size"),
            item(.appearance, \.transparencySection, ["appearance.background"], "opacity blur 透明 模糊 毛玻璃"),
            item(.appearance, \.cursorSection, ["appearance.cursor"], "cursor 光标"),
            item(.keyboard, \.quickInputShortcutLabel, ["keyboard.quickInput"], "shortcut 快捷键 快捷输入"),
            item(.keyboard, \.rightSidebarShortcutsSection, ["keyboard.inspector"], "inspector 快捷键 检查器 面板"),
            item(.keyboard, \.keybindingsSection, [], "keybind terminal shortcut 键位 终端 快捷键"),
            item(.git, \.gitSection, ["git.autoFetch"], "fetch Git 自动拉取"),
            item(.git, \.gitAISettingsTitle, ["git.commitAI"], "commit AI model prompt 提交 模型 提示词", anchor: "gitAI"),
            item(.ssh, \.sshSettingsTitle, [], "ssh host remote register 主机 远程 注册", anchor: "sshRegistration"),
            item(.plugins, \.officialPluginsSection, [], "plugin install 插件 安装 官方"),
            item(.plugins, \.installFromGitHubSection, [], "GitHub plugin repository 仓库 插件"),
            item(.advanced, \.settingsLocationsSection, [""], "config settings.json reload 配置文件 重载 来源", anchor: "settingsFiles"),
        ]
        for group in CoreSetting.Group.allCases {
            let fields = CoreSetting.all.filter { $0.group == group }
            result.append(.init(id: "core:" + group.rawValue, tab: group.tab, title: group.title(strings), anchor: group.title(strings),
                                keywords: fields.map { $0.english + " " + $0.chinese + " " + $0.helpEnglish + " " + $0.helpChinese + " " + $0.key }.joined(separator: " "),
                                prefixes: fields.map(\.id)))
        }
        // Every persisted descriptor routes to one group, by its most specific prefix.
        for descriptor in OhMyGhosttySettings.descriptors {
            guard let index = result.indices.max(by: { lhs, rhs in
                matchLength(descriptor.id, result[lhs].prefixes) < matchLength(descriptor.id, result[rhs].prefixes)
            }) else { continue }
            result[index].settingIDs.append(descriptor.id)
            result[index].keywords += " " + descriptor.description
        }
        return result
    }

    private static func matchLength(_ id: String, _ prefixes: [String]) -> Int {
        prefixes.filter { id.hasPrefix($0) }.map(\.count).max() ?? -1
    }
}
