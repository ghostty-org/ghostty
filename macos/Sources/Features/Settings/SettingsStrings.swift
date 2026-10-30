import Foundation

/// The OMG settings display language. `system` follows the macOS preferred
/// language; explicit values pin the UI regardless of system settings.
enum OhMyGhosttyLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
}

/// Resolved display strings for the Settings window. English is the source
/// language and Simplified Chinese is the first translation. Strings are kept
/// beside their translation so review and future languages stay mechanical.
struct SettingsStrings: Equatable, Sendable {
    let languageCode: String

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        switch language {
        case .english:
            languageCode = "en"
        case .simplifiedChinese:
            languageCode = "zh-Hans"
        case .system:
            languageCode = preferredLanguages.first.map {
                $0.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
            } ?? "en"
        }
    }

    var isChinese: Bool { languageCode.hasPrefix("zh") }
    var copyTitle: String { t("Copy", "复制") }
    var copiedTitle: String { t("Copied", "已复制") }
    var selectedTitle: String { t("Selected", "已选中") }
    func copyTitle(_ label: String) -> String { t("Copy " + label.lowercased(), "复制" + label) }
    func selectionCopyHint(_ label: String, value: String) -> String {
        t("Select " + label.lowercased() + " · ⌘C to copy · " + value, "选择" + label + " · ⌘C 复制 · " + value)
    }

    func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    // MARK: Window and navigation

    var windowTitle: String { t("Settings", "设置") }

    func tabTitle(_ tab: OhMyGhosttySettingsTab) -> String {
        switch tab {
        case .general: t("General", "通用")
        case .appearance: t("Appearance", "外观")
        case .tabs: t("Views & Tabs", "视图与标签")
        case .terminal: t("Shell & Sessions", "Shell 与会话")
        case .controls: t("Input & Controls", "输入与控制")
        case .editor: t("Editor", "编辑器")
        case .keyboard: t("Shortcuts", "快捷键")
        case .git: "Git"
        case .ssh: "SSH"
        case .agents: "Agent"
        case .plugins: t("Plugins", "插件")
        case .advanced: t("Advanced", "高级")
        }
    }

    // MARK: General

    var settingsSearch: String { t("Search Settings", "搜索设置") }
    var settingsNoResults: String { t("No matching settings", "没有找到匹配的设置") }
    var integrationsGroup: String { t("Integrations", "集成") }
    var gitAISettingsTitle: String { t("AI Commit Messages", "AI 提交信息") }
    var sshSettingsTitle: String { t("SSH Hosts", "SSH 主机") }
    var inheritCoreSetting: String { t("Follow Ghostty Config", "跟随 Ghostty 配置") }
    var newTerminalRequired: String { t("Applies to new terminals", "新建终端后生效") }
    var coreInheritanceCaption: String {
        t("Unset options follow your Ghostty configuration. Changes are saved as OMG overrides; your original config is not modified.",
          "未覆盖的选项跟随 Ghostty 配置。修改保存为 OMG 覆盖项，不改写原配置文件。")
    }
    var agentHistorySection: String { t("Agent History", "Agent 历史") }
    var agentBehaviorSection: String { t("Agent Behavior", "Agent 行为") }
    var sessionRecoverySection: String { t("Session Recovery", "会话恢复") }
    var sessionRecoveryCaption: String {
        t("Restore layout only, or restore terminal scrollback and supported Agent sessions at launch. This does not rerun arbitrary commands.",
          "启动时可只恢复布局，或恢复终端滚屏内容及受支持的 Agent 会话；不会重新运行任意命令。")
    }
    var settingsLocationsSection: String { t("Configuration Files", "配置文件") }
    var languageSection: String { t("Language", "语言") }
    var languageLabel: String { t("Display Language", "显示语言") }
    var languageSystem: String { t("Follow System", "跟随系统") }
    var languageCaption: String {
        t(
            "Follow System uses the macOS preferred language. Changes apply immediately.",
            "“跟随系统”使用 macOS 首选语言，更改后立即生效。"
        )
    }

    var sessionsSection: String { t("Sessions", "会话") }
    var agentHistoryLimitLabel: String { t("Historical Sessions Limit", "历史会话保留上限") }
    var agentHistoryLimitCaption: String {
        t(
            "Maximum number of agent conversations discovered and displayed in Agent History. Default is 10,000.",
            "Agent History 索引并展示的最大历史会话数量，默认值为 10,000 条。"
        )
    }
    var startupModeLabel: String { t("When OMG Opens", "重新打开 OMG 时") }
    func startupModeTitle(_ mode: OMGStartupMode) -> String {
        switch mode {
        case .newTerminal: t("Open a New Terminal", "打开新终端")
        case .restoreTabs: t("Restore All Tabs", "恢复所有标签页")
        case .restoreSessions: t("Restore All Sessions", "恢复所有会话")
        }
    }
    var startupModeCaption: String {
        t(
            "New Terminal opens a fresh Shell. Tabs restores windows, tabs, splits and directories with fresh local Shells. Sessions also restores saved output and validated command anchors, reconnects SSH and resumes eligible Agent conversations. Shell processes do not survive quitting OMG. Applies on next launch.",
            "新终端不保留旧标签；恢复标签页会还原窗口、标签、分屏和目录，但每个窗格都是新的本地 Shell；恢复会话还会回放旧输出和可验证命令锚点、重连 SSH，并恢复可用的 Agent 对话。退出 OMG 后 Shell 进程不会继续运行。下次启动生效。"
        )
    }
    var quitSection: String { t("Quit", "退出") }
    var quitWithoutConfirmationLabel: String {
        t("Quit Without Confirmation", "退出时无需确认")
    }
    var quitWithoutConfirmationCaption: String {
        t(
            "Quit immediately and terminate running terminal processes without asking.",
            "退出时直接终止仍在运行的终端进程，不再弹出确认。"
        )
    }

    // MARK: Git

    var gitSection: String { t("Git", "Git") }
    var gitAutoFetchLabel: String { t("Auto-Fetch Interval", "定时自动 Fetch 间隔") }
    var gitAutoFetchCaption: String {
        t(
            "Automatically fetches from remotes periodically in the background when repositories are active.",
            "仓库处于活跃状态时，在后台定期从远端自动 Fetch 更新。"
        )
    }
    func gitAutoFetchIntervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return t("Disabled", "关闭")
        case 1: return t("Every 1 minute", "每 1 分钟")
        case 2: return t("Every 2 minutes", "每 2 分钟")
        case 5: return t("Every 5 minutes", "每 5 分钟")
        case 10: return t("Every 10 minutes", "每 10 分钟")
        case 15: return t("Every 15 minutes", "每 15 分钟")
        case 30: return t("Every 30 minutes", "每 30 分钟")
        case 60: return t("Every 1 hour", "每 1 小时")
        default:
            return isChinese ? "每 \(minutes) 分钟" : "Every \(minutes) minutes"
        }
    }

    var configurationSection: String { t("Configuration", "配置") }
    var settingsFileLabel: String { t("OMG Settings", "OMG 设置文件") }
    var precedenceLabel: String { t("Precedence", "优先级") }
    var precedenceValue: String {
        t("Runtime → OMG → Ghostty → Defaults", "运行时 → OMG → Ghostty → 默认值")
    }
    var configurationCaption: String {
        t(
            "Tab layout, appearance, and plugin preferences each have one canonical page.",
            "标签页布局、外观和插件偏好各自只有一个规范设置页。"
        )
    }

    // MARK: Appearance

    var windowSection: String { t("Window", "窗口") }
    var appearancePickerLabel: String { t("Appearance", "外观") }
    var ghosttyConfigOption: String { t("Ghostty config", "跟随 Ghostty 配置") }

    func windowThemeTitle(_ theme: OhMyGhosttyWindowTheme) -> String {
        switch theme {
        case .system: t("System", "跟随系统")
        case .light: t("Light", "浅色")
        case .dark: t("Dark", "深色")
        }
    }

    var effectivePrefix: String { t("Effective", "生效值") }

    func appearanceSourceTitle(_ source: OhMyGhosttyAppearanceSource) -> String {
        switch source {
        case .ohMyGhosttyOverride: "OMG"
        case .ghosttyConfig: t("Ghostty config", "Ghostty 配置")
        case .builtInDefault: t("Built-in default", "内置默认值")
        }
    }

    var terminalThemeSection: String { t("OMG Theme", "OMG 主题") }
    var lightThemeLabel: String { t("Light Theme", "浅色主题") }
    var darkThemeLabel: String { t("Dark Theme", "深色主题") }
    var resolvedBackgroundLabel: String { t("Resolved Background", "实际背景色") }
    var themeCaption: String {
        t(
            "Foreground, selection, and palette remain owned by the selected Ghostty theme.",
            "前景色、选区颜色和调色板仍由所选 Ghostty 主题决定。"
        )
    }

    var fontSection: String { t("Font", "字体") }
    var fontFamilyLabel: String { t("Font Family", "字体") }
    var inheritGhosttyPlaceholder: String { t("Inherit Ghostty config", "继承 Ghostty 配置") }
    var fontSizeLabel: String { t("Font Size", "字号") }

    var transparencySection: String { t("Transparency", "透明度") }
    var backgroundOpacityLabel: String { t("Background Opacity", "背景不透明度") }
    var backgroundBlurLabel: String { t("Background Blur", "背景模糊") }

    func blurTitle(_ blur: OhMyGhosttyBackgroundBlur) -> String {
        switch blur {
        case .disabled: t("Off", "关闭")
        case .enabled: t("Blur", "模糊")
        case .macosGlassRegular: "macOS Glass — " + t("Regular", "常规")
        case .macosGlassClear: "macOS Glass — " + t("Clear", "通透")
        }
    }

    var cursorSection: String { t("Cursor", "光标") }
    var cursorStyleLabel: String { t("Style", "样式") }

    func cursorTitle(_ cursor: OhMyGhosttyCursorStyle) -> String {
        switch cursor {
        case .block: t("Block", "方块")
        case .bar: t("Bar", "竖线")
        case .underline: t("Underline", "下划线")
        case .blockHollow: t("Hollow Block", "空心方块")
        }
    }

    var appearanceTabsSection: String { t("Tabs", "标签页") }
    var rowDensityLabel: String { t("Row Density", "行密度") }

    func densityTitle(_ density: OhMyGhosttyTabRowDensity) -> String {
        switch density {
        case .compact: t("Compact", "紧凑")
        case .comfortable: t("Comfortable", "宽松")
        }
    }

    var tabIconSizeLabel: String { t("Icon Size", "图标大小") }
    var appearanceLiveCaption: String {
        t(
            "Changes apply live to existing terminals without restarting the shell.",
            "更改会实时应用到已有终端，无需重启 shell。"
        )
    }
    var resetAppearanceButton: String { t("Reset to Ghostty", "恢复为 Ghostty 配置") }

    // MARK: Tabs

    var layoutSection: String { t("Layout", "布局") }
    var tabLayoutLabel: String { t("Tab Layout", "标签页布局") }
    var horizontalOption: String { t("Horizontal", "水平") }
    var verticalOption: String { t("Vertical", "垂直") }
    var tabLayoutCaption: String {
        t(
            "Applies to newly created windows; existing terminals are not rebuilt.",
            "仅对新创建的窗口生效；已有终端不会重建。"
        )
    }
    var showSidebarLabel: String { t("Show Sidebar", "显示侧边栏") }
    var sidebarWidthLabel: String { t("Sidebar Width", "侧边栏宽度") }
    var rememberSidebarWidthLabel: String {
        t("Remember Resized Width", "记住调整后的宽度")
    }

    var organizationSection: String { t("Organization", "组织方式") }
    var groupingLabel: String { t("Grouping", "分组") }

    func groupingTitle(_ mode: GhosttyTabGroupingMode) -> String {
        switch mode {
        case .none: t("No Grouping", "不分组")
        case .project: t("By Project", "按项目")
        case .date: t("By Date", "按日期")
        }
    }

    var pathDisplayLabel: String { t("Path Display", "路径显示") }

    func pathDisplayTitle(_ mode: OhMyGhosttyTabPathDisplay) -> String {
        switch mode {
        case .fullPath: t("Full Path", "完整路径")
        case .folderName: t("Current Folder", "当前文件夹")
        }
    }

    var orderingLabel: String { t("Ordering", "排序") }

    func orderingTitle(_ mode: GhosttyTabOrderingMode) -> String {
        switch mode {
        case .manual: t("Manual", "手动")
        case .created: t("Created Time", "创建时间")
        case .recentlyUsed: t("Recently Used", "最近使用")
        }
    }

    var showShortcutLabelsLabel: String { t("Show Shortcut Labels", "显示快捷键标签") }
    var resetTabsButton: String { t("Reset Tabs Settings", "重置标签页设置") }

    // MARK: Terminal and Keyboard

    var ghosttySection: String { "Ghostty" }
    var openGhosttyConfigButton: String { t("Open Ghostty Configuration", "打开 Ghostty 配置") }
    var resizeRenderingSection: String { t("Resize Rendering", "尺寸调整渲染") }
    var terminalResizeRenderingLabel: String {
        t("Terminal Content Reflow", "终端内容重排")
    }
    var terminalResizeRenderingCaption: String {
        t(
            "Applies to Sidebars, split dividers, and Quick Input. During Drag feels continuous; On Release keeps terminal content fixed until resizing ends.",
            "适用于侧边栏、分屏分隔线和快速输入框。“拖动时”会连续重排；“松开时”会在尺寸调整结束前保持终端内容不变。"
        )
    }
    func terminalResizeRenderingTitle(_ mode: TerminalResizeRenderingMode) -> String {
        switch mode {
        case .duringDrag: t("During Drag", "拖动时重绘")
        case .onRelease: t("On Release", "松开时重绘")
        }
    }

    // MARK: Editor

    var editorBehaviorSection: String { t("Behavior", "行为") }
    var editorOpeningSection: String { t("Opening Location", "打开位置") }
    var editorFileOpenDestinationLabel: String { t("Open Files", "打开文件") }
    var editorDirectoryOpenDestinationLabel: String { t("Command-click Folders", "⌘ 点击文件夹") }
    var editorOpeningCaption: String {
        t("Files use this location when opened in the editor or with Command-click. The folder setting applies only to Command-click.",
          "在编辑器中打开文件或 ⌘ 点击文件时使用上述位置。文件夹设置仅适用于 ⌘ 点击。")
    }
    func editorOpenDestinationTitle(_ destination: EditorOpenDestination) -> String {
        switch destination {
        case .currentPane: t("Current Pane", "当前窗格")
        case .newTab: t("New Tab", "新标签页")
        case .splitRight: t("Split Right", "向右分屏")
        case .splitDown: t("Split Down", "向下分屏")
        case .splitLeft: t("Split Left", "向左分屏")
        case .splitUp: t("Split Up", "向上分屏")
        }
    }
    var editorTypographySection: String { t("Typography", "排版") }
    var editorKeymapPresetLabel: String { t("Keymap Preset", "键位预设") }

    func editorKeymapPresetTitle(_ preset: EditorKeymapPreset) -> String {
        switch preset {
        case .idea: "IDEA"
        case .vscode: "VS Code"
        }
    }

    var editorKeymapPresetCaption: String {
        t(
            "IDEA is the default. The preset changes only native editor commands.",
            "默认使用 IDEA。此预设只影响原生编辑器命令。"
        )
    }

    var editorBackgroundModeLabel: String { t("Background", "背景") }

    func editorBackgroundModeTitle(_ mode: EditorBackgroundMode) -> String {
        switch mode {
        case .followTerminal: t("Follow Terminal", "跟随终端")
        case .system: t("System Editor Background", "系统编辑器背景")
        }
    }

    var editorSyntaxThemeLabel: String { t("Syntax Theme", "代码风格主题") }
    func editorSyntaxThemeTitle(_ theme: EditorSyntaxTheme) -> String {
        theme == .followTerminal ? t("Follow OMG", "跟随 OMG 的主题设置") : theme.title
    }
    var editorThemeInheritedCaption: String {
        t("Colors, opacity and effects follow OMG Appearance settings.", "颜色、透明度与毛玻璃跟随 OMG 外观设置。")
    }
    var editorAutoClosePairsLabel: String { t("Auto-close Quotes and Brackets", "自动补全引号和括号") }
    var editorCatalogCaption: String {
        t("Themes set the background, syntax colors, selection and caret. They do not change code formatting.",
          "主题包含背景、语法配色、选区和光标颜色，不改变代码格式。")
    }
    var editorThemeSection: String { t("Editor Theme", "编辑器主题") }
    var followSystemThemeLabel: String { t("Switch with System Appearance", "跟随系统设置切换") }
    var themeVariantsLabel: String { t("Light and Dark Variants", "分别设置浅色与深色主题") }
    var unifiedThemeLabel: String { t("Theme Preset", "主题预设") }

    var editorFontFamilyLabel: String { t("Font Family", "字体") }
    func editorFontFamilyTitle(_ family: EditorFontFamily) -> String {
        family == .system ? t("System Monospaced", "系统等宽字体") : family.title
    }

    var editorWordWrapLabel: String { t("Word Wrap", "自动换行") }
    var editorFontSizeLabel: String { t("Font Size", "字号") }
    var editorTabWidthLabel: String { t("Tab Width", "Tab 宽度") }
    var resetEditorButton: String { t("Reset Editor Settings", "重置编辑器设置") }

    var quickInputSection: String { t("Quick Input", "快速输入") }
    var openQuickInputOnAgentStartLabel: String {
        t("Open Composer When Agent Starts", "打开 Agent 时展开输入框")
    }
    var openQuickInputOnAgentStartCaption: String {
        t(
            "Keeps terminal focus unchanged. Use Option-Command-arrow keys to move focus into or out of the composer.",
            "不会改变终端焦点。使用 Option-Command-方向键在终端与输入框之间切换焦点。"
        )
    }
    var openQuickInputOnAgentCompleteLabel: String {
        t("Open Composer When Agent Completes", "Agent 会话完成时自动打开输入框")
    }
    var openQuickInputOnAgentCompleteCaption: String {
        t(
            "Opens only for a newly completed Agent in the focused Pane and keeps terminal focus unchanged.",
            "仅在当前 Pane 中的 Agent 会话刚完成时打开，并保持终端焦点不变。"
        )
    }
    var quickInputShortcutLabel: String { t("Open Composer", "打开输入框") }
    var quickInputShortcutCaption: String {
        t(
            "Click the shortcut, then press a new key combination. The default is Command-Shift-E.",
            "点击快捷键后按下新的组合键。默认快捷键为 Command-Shift-E。"
        )
    }
    var quickInputImportLabel: String { t("Import Agent Draft", "导入 Agent 草稿") }
    var quickInputImportCaption: String {
        t("Automatically copy the agent's input when opening Quick Input. Enabled by default; original input is preserved. Open a new terminal after enabling.",
          "打开 Quick Input 时自动复制 Agent 输入，默认开启，原输入会保留。重新启用后需新建终端。")
    }
    var quickInputImportInvalid: String {
        t("Use up to four comma-separated shortcuts with control, option or shift and a letter or digit.",
          "使用 control、option、shift 加字母或数字；多个按键组合用逗号分隔，最多四组。")
    }
    var quickInputDraftImported: String {
        t("Draft imported. Sending will append only text after the original prefix.",
          "草稿已导入。发送时只会追加原有内容之后新增的文字。")
    }
    var quickInputHeightLabel: String { t("Composer Height", "输入框高度") }
    var quickInputHeightCaption: String {
        t(
            "Drag the divider above the composer to resize it. The last committed height is remembered.",
            "拖动输入框上方的分隔线可调整高度，并会记住最后确认的高度。"
        )
    }
    var quickInputSendTitle: String { t("Send", "发送") }
    var quickInputQueueTitle: String { t("Queue", "排队") }
    var quickInputCancelTitle: String { t("Cancel", "取消") }
    var quickInputSaveTitle: String { t("Save Edit", "保存修改") }
    var quickInputMoveTitle: String { t("Move to Queue End", "移到队尾") }
    var quickInputHistoryTitle: String { t("Sent History", "发送历史") }
    var quickInputHistoryButton: String { t("History", "历史") }
    var quickInputHistoryButtonHelp: String { t("History · ⌘⇧H", "历史 · ⌘⇧H") }
    var quickInputPinHelp: String {
        t("Pin Quick Input: keep it open after sending or queueing", "固定快速输入：发送或排队后保持展开")
    }
    var quickInputUnpinHelp: String { t("Unpin Quick Input", "取消固定快速输入") }
    var quickInputHistorySearch: String { t("Search messages…", "搜索历史内容…") }
    var quickInputHistoryClearSearch: String { t("Clear search", "清除搜索") }
    var quickInputHistoryExitSearch: String { t("Exit search", "退出搜索") }
    var quickInputHistoryEmpty: String { t("No history in this scope yet", "当前范围暂无发送历史") }
    var quickInputHistoryNoMatches: String { t("No matching messages", "没有匹配的历史内容") }
    var quickInputHistoryAppendHint: String {
        t("↑↓ Select · Enter to append · Esc to close", "↑↓ 选择 · Enter 追加 · Esc 关闭")
    }
    var quickInputHistoryReplaceHint: String {
        t("↑↓ Select · Enter to replace · Esc to close", "↑↓ 选择 · Enter 覆盖 · Esc 关闭")
    }
    var quickInputHistoryInsertionLabel: String { t("History Selection", "历史回填方式") }
    func quickInputHistoryInsertionName(_ mode: QuickInputHistoryInsertionMode) -> String {
        switch mode {
        case .append: t("Append to Draft", "追加到草稿")
        case .replace: t("Replace Draft", "覆盖草稿")
        }
    }
    var quickInputHistoryStorageError: String {
        t("History storage failed. Current in-memory history is still available.",
          "历史存储失败，当前内存中的历史仍可使用。")
    }
    var quickInputHistoryScopeLabel: String { t("History Visibility", "历史可见范围") }
    func quickInputHistoryScopeName(_ scope: QuickInputHistoryScope) -> String {
        switch scope {
        case .pane: t("Current Pane", "当前 Pane")
        case .tab: t("Current Tab", "当前 Tab")
        case .global: t("All Windows", "所有窗口")
        }
    }
    var quickInputHistoryRetentionLabel: String { t("History Expiration", "历史过期时间") }
    var quickInputHistoryDayUnit: String { t("days", "天") }
    func quickInputHistoryRetentionValue(_ days: Int) -> String { t("\(days) days", "\(days) 天") }
    var quickInputHistoryKeepLabel: String { t("Keep History After Quitting OMG", "退出 OMG 后保留历史") }
    var quickInputHistoryPrivacyCaption: String {
        t("Stored locally, unencrypted. Messages may contain sensitive data. Turning this off deletes the saved copy; memory history remains until exit. Expiration applies in both modes.",
          "历史在本机明文保存，内容可能包含敏感信息。关闭后删除磁盘副本，内存历史保留至退出；两种模式都按过期时间清理。")
    }
    var quickInputHistoryClearButton: String { t("Clear All Quick Input History…", "清空所有 Quick Input 历史…") }
    var quickInputHistoryClearTitle: String { t("Clear all Quick Input history?", "清空所有 Quick Input 历史？") }
    var quickInputHistoryClearMessage: String {
        t("Removes history from all panes and tabs, including the saved copy. Drafts and queues are unchanged.",
          "删除所有 Pane 和 Tab 的发送历史及磁盘副本，不影响草稿或待发送队列。")
    }
    var quickInputHistoryClearConfirm: String { t("Clear History", "清空历史") }
    var quickInputHistoryClearCancel: String { t("Cancel", "取消") }
    var resetShortcutButton: String { t("Reset", "重置") }
    var rightSidebarShortcutsSection: String { t("Right Sidebar Shortcuts", "右侧边栏快捷键") }
    var rightSidebarShortcutsCaption: String {
        t(
            "Shortcuts to open, switch between, or toggle right sidebar panels by position. Pressing the active panel's shortcut again hides the sidebar.",
            "按展示位置快速打开、切换或隐藏右侧边栏面板。再次按下当前激活面板的快捷键可将其隐藏。"
        )
    }
    func inspectorPanelSlotLabel(slot: Int) -> String {
        t("Panel \(slot)", "面板 \(slot)")
    }
    func shortcutConflictCaption(_ title: String) -> String {
        t(
            "This shortcut is also used by “\(title)”. Quick Input takes precedence in terminal windows.",
            "此快捷键也用于“\(title)”。在终端窗口中，快速输入会优先处理。"
        )
    }
    var keybindingsSection: String { t("Ghostty Keybindings", "Ghostty 快捷键") }
    var keybindingsCaption: String {
        t(
            "Other keyboard shortcuts are defined by Ghostty configuration. Position labels are configured once in Tabs.",
            "其他键盘快捷键由 Ghostty 配置定义。位置标签在“标签页”中统一设置。"
        )
    }

    // MARK: Plugins

    var officialPluginsSection: String { t("Official Plugins", "官方插件") }
    var officialPluginsCaption: String {
        t(
            "Plugins are installed independently from OMG. SSH uses your existing OpenSSH configuration. Configure status Hooks in Integrations → Agent.",
            "插件独立于 OMG 安装，SSH 沿用现有 OpenSSH 配置。状态 Hook 请前往“集成 → Agent”配置。"
        )
    }
    var installFromGitHubSection: String { t("Install from GitHub", "从 GitHub 安装") }
    var installButton: String { t("Install", "安装") }
    var installFromGitHubCaption: String {
        t(
            "Only HTTPS GitHub repositories with a validated manifest.json are accepted. Installed external executables remain disabled until the supervised runtime is available.",
            "仅接受带有效 manifest.json 的 HTTPS GitHub 仓库。在受监管的运行时可用之前，已安装的外部可执行文件保持禁用。"
        )
    }
    var invalidGitHubURL: String {
        t("Enter a valid HTTPS GitHub repository URL.", "请输入有效的 HTTPS GitHub 仓库地址。")
    }

    func pluginOperationLabel(_ operation: String) -> String {
        switch operation {
        case "Installing": t("Installing", "安装中")
        case "Disabling": t("Disabling", "禁用中")
        case "Enabling": t("Enabling", "启用中")
        case "Uninstalling": t("Uninstalling", "卸载中")
        case "Downloading": t("Downloading", "下载中")
        default: operation
        }
    }

    var pluginNotInstalled: String { t("Not Installed", "未安装") }
    var pluginEnabled: String { t("Enabled", "已启用") }
    var pluginDisabled: String { t("Disabled", "已禁用") }
    var pluginDisableButton: String { t("Disable", "禁用") }
    var pluginEnableButton: String { t("Enable", "启用") }
    var pluginUpdateButton: String { t("Update", "更新") }
    var pluginUninstallButton: String { t("Uninstall", "卸载") }
    var sshPluginCaption: String {
        t(
            "SSH aliases and remote Files through the system OpenSSH/SFTP client.",
            "通过系统 OpenSSH/SFTP 客户端使用 SSH 别名与远程文件。"
        )
    }
    var genericPluginCaption: String { t("OMG plugin", "OMG 插件") }

    var agentIntegrationSection: String { "Agent" }
    var sshAutomaticRegistration: String { t("Register hosts after connecting in OMG", "连接成功后自动注册主机") }
    var sshRegistrationTarget: String { t("Choose an SSH host to register", "选择要注册的 SSH 主机") }
    var sshRegister: String { t("Register", "注册") }
    var sshUnregister: String { t("Unregister", "取消注册") }
    var sshCached: String { t("Offline · cached", "离线 · 已缓存") }
    var sshConnected: String { t("Connected", "已连接") }
    var sshRegistrationCaption: String {
        t("Choose a host from SSH config or an active connection. Registration connects on demand and caches Agent versions and Hook status locally. Automatic registration still requires a connection in OMG.",
          "可从 SSH config 或当前连接中选择主机。点击注册后按需连接，并将 Agent 版本与 Hook 状态缓存在本机；自动注册仍仅在 OMG 建立连接后进行。")
    }
    var sshAgentHookTitle: String { t("Set up SSH Agent status", "接入 SSH Agent 状态") }
    var sshRecoveryTitle: String { t("SSH disconnected", "SSH 连接已断开") }
    var sshRecoveryReconnectHere: String { t("Reconnect Here", "在当前面板重连") }
    var sshRecoveryReconnectHereHelp: String {
        t("Replace this pane's terminal with a new SSH connection using the saved arguments. Output from the interrupted session is discarded.",
          "用已保存的参数在这个面板里重新连接，替换当前终端；断线前的输出会被丢弃。")
    }
    var runtimeRecoveryReconnect: String { t("Reconnect Session", "重新连接会话") }
    var runtimeRecoveryHelp: String {
        t("Reconnect to the original remote session in this pane. Recovery requires the session to still exist on the remote host.",
          "在当前面板重新连接原远端会话；恢复需要该会话仍保留在远端主机上。")
    }
    var sshRecoveryReconnect: String { t("Reconnect in New Tab", "在新标签页重连") }
    var sshRecoveryDismissHelp: String {
        t("Dismiss this prompt and keep using this pane as a local terminal.",
          "关闭提示，将此面板作为本地终端继续使用。")
    }
    var sshRecoveryReconnectHelp: String {
        t("Reconnect with the saved SSH arguments in a new tab. This tab keeps its current contents.",
          "使用已保存的 SSH 参数在新标签页中重新连接；当前标签页内容保持不变。")
    }
    func sshRecoveryResumesAgent(_ name: String) -> String {
        t("Will also resume the \(name) conversation.", "同时会恢复 \(name) 的会话。")
    }
    var sshAgentHookExplanation: String {
        t("Remote Agents need their own OMG status Hooks; installing or upgrading OMG does not copy this Mac’s Hooks to SSH accounts. Check this host, then choose Install Extension for the Agents you use. This does not upgrade any CLI. Restart the affected Agent after installation.",
          "远端 Agent 需要单独安装 OMG 状态 Hook；安装或升级 OMG 不会将本机 Hook 同步到 SSH 账户。检查此主机后，为使用的 Agent 选择“安装状态扩展”，不会升级 CLI。安装后请重启对应 Agent。")
    }
    var sshAgentHookCheck: String { t("Check & Set Up…", "检查并设置…") }
    var sshAgentHookDismiss: String { t("Dismiss for this tab", "此标签页暂不提示") }
    func sshAgentHooksNeeded(_ names: String) -> String {
        t("Status Hooks need setup: \(names).", "以下 Agent 的状态 Hook 需要接入：\(names)。")
    }
    var sshAgentHookPrompt: String {
        t("Agent icons and task status over SSH require Hooks in this remote account. Check and choose which to install; nothing is installed automatically.",
          "SSH 内的 Agent 图标与任务状态依赖远端账户的 Hook。可检查后选择安装，不会自动修改远端配置。")
    }
    var agentSetupAll: String { t("Enable All Detected", "一键接入") }
    var agentAlreadySetup: String { t("All Hooks Ready", "Hook 已全部接入") }
    var agentSetupQueued: String { t("Waiting for the current check; setup will continue automatically…", "等待当前检查完成，将自动继续接入…") }
    var agentSetupComplete: String { t("Status Hooks are ready. This setup did not upgrade any CLI.", "状态 Hook 已接入，本次接入未升级 CLI。") }
    var agentSetupNoneFound: String { t("No supported Agents detected", "未发现可接入的 Agent") }
    var agentSetupIncomplete: String { t("Some Hooks could not be installed. You can retry here.", "部分 Hook 未能接入，可在此重试。") }
    var agentRetrySetup: String { t("Retry Setup", "重试接入") }
    var agentSetupCheckFailed: String { t("Agent check or Hook setup did not complete", "Agent 检查或 Hook 接入未完成") }
    var agentCLIUpdateFailed: String { t("CLI maintenance did not complete", "CLI 更新或检查未完成") }
    var agentTechnicalDetails: String { t("Technical details", "技术详情") }
    var agentCLIErrorIndependent: String { t("This does not mean status Hook installation failed.", "此错误不代表状态 Hook 接入失败。") }
    var agentCLIAuthenticationHint: String {
        t("The vendor updater requires authentication. Check that CLI's login on this host, then retry its update in the Agent details.",
          "原生升级程序认证失败。请在对应主机检查该 CLI 的登录状态，再从 Agent 详情重试升级。")
    }
    var agentCLIPackageManagerHint: String {
        t("This CLI must be upgraded through its package manager. Verified npm installations use npm, not the native updater.",
          "此 CLI 需通过原包管理器升级；已验证的 npm 安装应走 npm，而不是原生升级程序。")
    }
    var agentSSHNotConnected: String { t("Not connected in OMG · cached", "OMG 内未连接 · 已缓存") }
    var agentSetupCustom: String { t("Customize…", "自定义…") }
    var agentSetupDismiss: String { t("Only notify me about new Agents", "仅在发现新 Agent 时提醒") }
    var agentSetupBrief: String {
        t("Enable status Hooks for detected Agents. No CLI upgrades. Your choice is remembered for this host.",
          "为检测到的 Agent 接入状态 Hook，不升级 CLI。此主机会记住你的选择。")
    }
    var agentListTitle: String { t("Coding Agents", "Coding Agents") }
    var agentLocalMachine: String { t("Agents and integrations on this Mac", "此 Mac 的 Agent 与集成") }
    var agentMaintenanceOK: String { t("Completed", "已完成") }
    var agentMaintenanceFailed: String { t("Some operations failed", "部分操作失败") }
    var agentEnabled: String { t("On", "已接入") }
    var agentDisabled: String { t("Off", "未接入") }
    var agentStatusIntegration: String { t("Status integration", "状态集成") }
    var agentRestartBrief: String { t("Hooks saved. Restart affected Agents to load them.", "Hook 已保存，重启对应 Agent 后生效。") }
    var agentMaintenance: String { t("Automatic maintenance", "自动维护") }
    var agentAutoHooksBrief: String { t("Auto-update Hooks", "Hook 自动更新") }
    var agentAutoCLIsBrief: String { t("Auto-update CLIs", "CLI 自动更新") }
    var agentScheduleTitle: String { t("Update Schedule", "更新计划") }
    var agentHooksUpdateScope: String { t("Keep enabled status integrations up to date", "保持已接入的状态扩展为最新版本") }
    var agentCLIUpdateScope: String { t("Update supported Agent applications", "更新受支持的 Agent 应用") }
    var agentLaunchReconnectShort: String { t("Also at launch / reconnect", "启动 / 重连时检查") }
    var agentCheckOnConnection: String { t("Also check at launch / SSH reconnect", "启动 / SSH 重连时也检查") }
    var agentScheduleBrief: String {
        t("Updates existing Hooks and supported CLIs while OMG is open; SSH must be connected. Does not install missing integrations, block quitting or end Agent sessions.",
          "在 OMG 运行时更新已接入的 Hook 和受支持的 CLI，SSH 需保持连接。不自动接入未启用的 Agent，不阻塞退出或结束 Agent 会话。")
    }
    var agentConnectionAndTimer: String { t("Launch / reconnect + scheduled", "启动 / 重连 + 定时") }
    var agentTimerOnly: String { t("Scheduled while OMG is open", "OMG 运行期间定时执行") }
    var agentNextCheck: String { t("Next check", "下次检查") }
    var agentCheckDue: String { t("Check due", "等待检查") }
    var agentLastMaintenance: String { t("Last maintenance:", "上次自动维护：") }
    var agentDiscovering: String { t("Checking Agents…", "正在检测 Agent…") }
    var agentInstallingHooks: String { t("Installing Hooks…", "正在接入 Hook…") }
    var agentUpdatingCLI: String { t("Updating CLI…", "正在更新 CLI…") }
    var agentLegacyCLIScope: String { t("Previously selected CLIs only. Turn off and on to include all supported CLIs.", "保留之前选择的 CLI 范围；关闭后再开启可应用于全部受支持的 CLI。") }
    var agentUpdateSettings: String { t("Update Settings", "更新设置") }
    var agentManualChecks: String { t("Manual checks", "手动检查") }
    var agentAutomaticHooksShort: String { t("Auto-update Hooks", "自动更新 Hooks") }
    var agentCheckOnly: String { t("Check for updates", "检查更新") }
    var agentWaitingForConnection: String {
        t("Connect this SSH host in OMG to resume automatic maintenance. Manual checks remain available.",
          "在 OMG 中连接此 SSH 主机后恢复自动维护；仍可手动检查。")
    }
    var agentActions: String { t("Agent actions", "Agent 操作") }
    var agentCLIOptions: String { t("CLI Settings", "CLI 设置") }
    var agentIntegrationExplanation: String {
        t("OMG status extensions (Hooks) control tab icons and task status. CLI updates upgrade the Agent itself; their update methods are independent.",
          "OMG 状态扩展（Hook）负责 Tab 图标和任务状态；CLI 更新升级 Agent 本体，两者独立管理。")
    }
    var agentIntegrationUpdateAvailable: String {
        t("Installed status extensions differ from this OMG version. Update them using the extension buttons.",
          "已安装的状态扩展与当前 OMG 内置版本不同，请使用扩展按钮更新。")
    }
    var agentIntegrationReload: String {
        t("Status extensions changed. Restart the affected Agent sessions, or use /reload in Pi. Existing sessions may still use the previous extension.",
          "状态扩展已变更。请重启对应 Agent 会话，或在 Pi 中执行 /reload；已有会话可能仍使用旧扩展。")
    }
    var agentInstallHook: String { t("Install Extension", "安装状态扩展") }
    var agentUpdateHook: String { t("Update Extension", "更新状态扩展") }
    var agentReinstallHook: String { t("Reinstall Extension", "重装状态扩展") }
    var agentInstallDetector: String { t("Install Detector", "安装检测器") }
    var agentUpdateDetector: String { t("Update Detector", "更新检测器") }
    var agentReinstallDetector: String { t("Reinstall Detector", "重新安装检测器") }
    var agentHostLabel: String { t("Host", "主机") }
    var agentLocalHost: String { t("This Mac", "本机") }
    var agentAutomaticCheck: String { t("Check for Updates Automatically", "自动检测更新") }
    var agentAutomaticHooks: String { t("Automatically Update Installed Status Extensions", "自动更新已安装的状态扩展") }
    var agentAutomaticCLI: String { t("Auto-update CLI", "自动更新 CLI") }
    var agentCheckInterval: String { t("Check Interval", "检查频率") }
    var agentEveryHour: String { t("Every Hour", "每小时") }
    var agentEveryDay: String { t("Every Day", "每天") }
    var agentEveryWeek: String { t("Every Week", "每周") }
    var agentCheckNow: String { t("Check Now", "立即检查") }
    var agentLastChecked: String { t("Last captured:", "上次采集：") }
    var agentUpdateCLI: String { t("Update CLI", "更新 CLI") }
    var agentCheckAndUpdateCLI: String { t("Check & Update CLI", "检查并更新 CLI") }
    var agentNotChecked: String { t("Not Checked", "尚未检查") }
    var agentCLIMissing: String { t("Not Found in PATH", "未在 PATH 中找到") }
    var agentVersionUnknown: String { t("Version Unknown", "版本未知") }
    var agentExternalUpdater: String { t("CLI: use its original installer; status extensions can still be updated here.", "CLI 请使用原安装方式更新；状态扩展仍可在此更新。") }
    var agentDetectorUpdateExplanation: String {
        t("OMG currently uses a detector, not a vendor status Hook, for this Agent. Detection improvements ship with OMG; reinstalling the detector only enables detection.",
          "OMG 当前通过检测器识别此 Agent，尚未接入厂商状态 Hook。检测逻辑随 OMG 更新；重装检测器仅启用检测功能。")
    }
    var agentHostDetectorOnly: String { t("Detector is managed on this Mac", "检测器由本机管理") }
    var agentUpdateScopeCaption: String {
        t("After an OMG upgrade, enabled automatic checks inspect installed status extensions immediately, regardless of the interval. Automatic extension updates are off by default. Only existing integrations are updated; CLI updates have separate settings.",
          "OMG 升级后，已启用的自动检查会立即检查状态扩展，不受检查周期限制。扩展自动更新默认关闭，仅更新已有集成；CLI 更新独立设置。")
    }
    var agentLocalScopeCaption: String { t("These update settings apply to this Mac only.", "以上更新设置仅适用于本机。") }
    var agentSSHScopeCaption: String {
        t("Automatic checks and updates run only while this host is connected in OMG. Scheduling stays on this Mac; no remote daemon is installed. Manual checks remain available. Requires non-interactive OpenSSH access and Python 3.",
          "仅在 OMG 连接此主机时自动检查和更新。定时任务由本机管理，不在远端安装常驻服务。仍可手动检查。需要免交互 OpenSSH 登录和 Python 3。")
    }
    var agentStatusHooksLabel: String {
        t("Enable Normalized Status Events (OMG-wide)", "启用规范化状态事件（OMG 全局）")
    }
    var agentDetectorMissing: String { t("Detector Not Installed", "未安装检测器") }
    var agentDetectorUpdateRequired: String {
        t("Detector Update Required", "需要更新检测器")
    }
    var agentDetectorCurrent: String { t("Detector Installed", "已安装检测器") }
    var agentHooksMissing: String { t("Hooks Not Installed", "未安装 Hooks") }
    var agentHooksUpdateRequired: String { t("Hook Update Required", "需要更新 Hooks") }
    var agentHooksCurrent: String { t("Hooks Installed", "已安装 Hooks") }
    var agentUpdateButton: String { t("Update", "更新") }
    var agentInstallButton: String { t("Install", "安装") }
    var agentRemoveButton: String { t("Remove", "移除") }
    var exportSSHInstallerButton: String { t("Export SSH Installer…", "导出 SSH 安装脚本…") }
    var agentHooksCaption: String {
        t(
            "Hooks write bounded presentation-only OSC events to the owning terminal. Exported hooks can be reviewed and run explicitly in an SSH account. Agent icons and status are presented by Vertical Tabs; Horizontal keeps Ghostty's native tab UI.",
            "Hooks 只向所属终端写入受限的展示类 OSC 事件。导出的脚本可以先审阅，再在 SSH 账户中显式执行。Agent 图标与状态由垂直标签页展示；水平标签页保持 Ghostty 原生界面。"
        )
    }

    var notificationsSection: String { t("Notifications", "通知") }
    var notifyTaskCompleteLabel: String { t("Task Complete", "任务完成") }
    var notifyAttentionLabel: String { t("Attention Required", "需要注意") }
    var notificationSoundLabel: String { t("Play Sound", "播放声音") }

    // MARK: Native Session Runtime

    var runtimeTitle: String { t("Persistent SSH sessions", "SSH 后台会话") }
    var runtimeHostPlaceholder: String { t("SSH host or user@host", "SSH 主机别名或 user@host") }
    var runtimeConnect: String { t("Connect", "连接") }
    var runtimeConnectCaption: String {
        t("Uses your SSH configuration and keys. Installs the runtime and, when Python 3 is available, OMG recovery hooks for Codex, Claude and Pi in the remote user's directory.",
          "使用现有 SSH 配置与密钥，自动在远端用户目录安装 Runtime；有 Python 3 时同时安装 Codex、Claude、Pi 的 OMG 对话恢复 hooks。")
    }
    var runtimeDetachedHours: String { t("Keep disconnected sessions (hours)", "断开后最长保留（小时）") }
    var runtimeDetachedCaption: String {
        t("Defaults to 72 hours (3 days). 0 disables only this time limit, not completion cleanup. Output does not extend it. Changes apply to new sessions.",
          "默认 72 小时（3 天）。0 仅关闭此时间上限，不影响任务完成后回收。持续输出不会延长期限；修改对新会话生效。")
    }
    var runtimeExpirationPlaceholder: String { t("Optional deadline, e.g. 2026-12-01T18:00:00Z", "可选截止时间，例如 2026-12-01T18:00:00Z") }
    var runtimeCloseOnDone: String { t("Close after Agent task completion [Beta]", "Agent 任务完成后回收【Beta】") }
    var runtimeCloseOnDoneCaption: String {
        t("Off by default. When enabled, closes disconnected Codex, Claude and Pi sessions only after verified completion and an existing conversation record; reopening resumes that conversation. Unsupported Agents keep running like ordinary processes. The detached time limit and explicit close still apply. Changes apply to new sessions.",
          "默认关闭。开启后，仅在无人连接、确认任务完成且已有对话记录时回收 Codex、Claude、Pi，再次打开恢复原对话。不支持的 Agent 与普通进程一样继续后台运行，仍受保留期限和显式关闭控制。修改对新会话生效。")
    }
    var runtimeDoneGrace: String { t("Completion grace period (seconds)", "完成后的宽限期（秒）") }
    var runtimeDoneGraceCaption: String {
        t("Wait after both disconnection and verified completion. Reconnecting or new work cancels this pending cleanup; the maximum detached lifetime still applies independently.",
          "断开连接且确认任务完成后，再等待这段时间。重连或新任务会取消本次完成回收；最长保留期限仍独立生效。")
    }
    var runtimeIdleCaption: String {
        t("The remote manager exits after 5 minutes with no active sessions or client connections. Running or waiting Agent sessions are not an idle manager.",
          "远端管理进程在没有活跃会话和客户端连接达 5 分钟后退出。仍有 Agent 运行或等待输入时，不属于管理进程空闲。")
    }
    var runtimeInvalidDeadline: String { t("Enter an ISO-8601 deadline or leave it empty.", "请填写 ISO-8601 截止时间，或留空。") }

    // MARK: Advanced

    var forkSettingsSection: String { t("Settings File", "设置文件") }
    var fileLabel: String { t("File", "文件") }
    var openFileButton: String { t("Open File", "打开文件") }
    var reloadButton: String { t("Reload", "重新加载") }
    var revealButton: String { t("Reveal", "在访达中显示") }
    var resetThemeHelp: String { t("Reset to Ghostty config", "恢复为 Ghostty 配置") }
}
