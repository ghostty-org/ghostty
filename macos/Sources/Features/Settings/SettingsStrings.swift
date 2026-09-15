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

    private func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    // MARK: Window and navigation

    var windowTitle: String { t("Settings", "设置") }

    func tabTitle(_ tab: OhMyGhosttySettingsTab) -> String {
        switch tab {
        case .general: t("General", "通用")
        case .appearance: t("Appearance", "外观")
        case .tabs: t("Tabs", "标签页")
        case .terminal: t("Terminal", "终端")
        case .editor: t("Editor", "编辑器")
        case .keyboard: t("Keyboard", "键盘")
        case .plugins: t("Plugins", "插件")
        case .advanced: t("Advanced", "高级")
        }
    }

    // MARK: General

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
    var restoreSessionsLabel: String {
        t("Restore Windows and Agent Sessions", "恢复窗口与 Agent 会话")
    }
    var restoreSessionsCaption: String {
        t(
            "Restores open windows, tabs, splits, working directories, and agents that were still running when OMG quit.",
            "恢复 OMG 退出时仍然打开的窗口、标签页、分屏、工作目录以及仍在运行的 Agent。"
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

    var quickInputSection: String { t("Agent Quick Input", "Agent 快速输入") }
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
    var quickInputHeightLabel: String { t("Composer Height", "输入框高度") }
    var quickInputHeightCaption: String {
        t(
            "Drag the divider above the composer to resize it. The last committed height is remembered.",
            "拖动输入框上方的分隔线可调整高度，并会记住最后确认的高度。"
        )
    }
    var resetShortcutButton: String { t("Reset", "重置") }
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
            "Official plugins are installed independently from the OMG app. SSH uses your existing OpenSSH configuration and credentials. Built-in agent hook adapters are configured below.",
            "官方插件独立于 OMG 应用安装。SSH 使用你现有的 OpenSSH 配置与凭据。内置 Agent 状态适配器在下方配置。"
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

    var agentIntegrationSection: String { t("Agent Integration", "Agent 集成") }
    var agentHostLabel: String { t("Host", "主机") }
    var agentLocalHost: String { t("This Mac", "本机") }
    var agentAutomaticCheck: String { t("Check for Updates Automatically", "自动检测更新") }
    var agentAutomaticHooks: String { t("Automatically Update Installed Hooks", "自动更新已安装的 Hooks") }
    var agentAutomaticCLI: String { t("Auto-update CLI", "自动更新 CLI") }
    var agentCheckInterval: String { t("Check Interval", "检查频率") }
    var agentEveryHour: String { t("Every Hour", "每小时") }
    var agentEveryDay: String { t("Every Day", "每天") }
    var agentEveryWeek: String { t("Every Week", "每周") }
    var agentCheckNow: String { t("Check Now", "立即检查") }
    var agentLastChecked: String { t("Hooks last checked:", "Hooks 上次检查成功：") }
    var agentUpdateCLI: String { t("Update CLI", "更新 CLI") }
    var agentNotChecked: String { t("Not Checked", "尚未检查") }
    var agentCLIMissing: String { t("Not Found in PATH", "未在 PATH 中找到") }
    var agentVersionUnknown: String { t("Version Unknown", "版本未知") }
    var agentExternalUpdater: String { t("Update with Original Installer", "请使用原安装方式更新") }
    var agentHostDetectorOnly: String { t("Detector is managed on this Mac", "检测器由本机管理") }
    var agentUpdateScopeCaption: String {
        t("Checks run while OMG is open. Automatic installation is off by default and only updates existing installations. CLI updates support verified global npm installations.",
          "OMG 运行期间定时检查。自动安装默认关闭，只更新已安装的项目。CLI 更新支持已核实来源的 npm 全局安装。")
    }
    var agentLocalScopeCaption: String { t("These update settings apply to this Mac only.", "以上更新设置仅适用于本机。") }
    var agentSSHScopeCaption: String {
        t("These update settings apply to the selected SSH account. Uses system OpenSSH configuration and requires non-interactive SSH access and Python 3. CLI checks use the remote login shell. Offline hosts report an error and retry at the next interval.",
          "以上更新设置仅适用于所选 SSH 账户。使用系统 OpenSSH 配置，需要免交互 SSH 登录和 Python 3。CLI 检查使用远端登录 Shell。离线主机显示错误并在下个周期重试。")
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

    // MARK: Advanced

    var forkSettingsSection: String { t("Settings File", "设置文件") }
    var fileLabel: String { t("File", "文件") }
    var openFileButton: String { t("Open File", "打开文件") }
    var reloadButton: String { t("Reload", "重新加载") }
    var revealButton: String { t("Reveal", "在访达中显示") }
    var resetThemeHelp: String { t("Reset to Ghostty config", "恢复为 Ghostty 配置") }
}
