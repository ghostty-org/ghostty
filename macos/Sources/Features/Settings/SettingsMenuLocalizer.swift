import AppKit

/// Applies the selected OMG language to the static macOS main-menu hierarchy.
/// Only exact, app-owned titles are translated; dynamic window names, Services,
/// plugin content, and arbitrary menu items are left untouched.
enum SettingsMenuLocalizer {
    private static let titlePairs: [(english: String, chinese: String)] = [
        ("About OMG", "关于 OMG"),
        ("Check for Updates...", "检查更新…"),
        ("Settings…", "设置…"),
        ("Reload Configuration", "重新加载配置"),
        ("Secure Keyboard Entry", "安全键盘输入"),
        ("Make OMG the Default Terminal", "将 OMG 设为默认终端"),
        ("Services", "服务"),
        ("Hide OMG", "隐藏 OMG"),
        ("Hide Others", "隐藏其他"),
        ("Show All", "全部显示"),
        ("Quit OMG", "退出 OMG"),

        ("File", "文件"),
        ("New Window", "新建窗口"),
        ("New Tab", "新建标签页"),
        ("Split Right", "向右分屏"),
        ("Split Left", "向左分屏"),
        ("Split Down", "向下分屏"),
        ("Split Up", "向上分屏"),
        ("Close", "关闭"),
        ("Close Tab", "关闭标签页"),
        ("Close Window", "关闭窗口"),
        ("Close All Windows", "关闭所有窗口"),

        ("Edit", "编辑"),
        ("Undo", "撤销"),
        ("Redo", "重做"),
        ("Cut", "剪切"),
        ("Copy", "复制"),
        ("Paste", "粘贴"),
        ("Paste Selection", "粘贴选区"),
        ("Select All", "全选"),
        ("Find", "查找"),
        ("Find...", "查找…"),
        ("Find Next", "查找下一个"),
        ("Find Previous", "查找上一个"),
        ("Hide Find Bar", "隐藏查找栏"),
        ("Use Selection for Find", "使用选区查找"),
        ("Jump to Selection", "跳转到选区"),

        ("View", "显示"),
        ("Reset Font Size", "重置字体大小"),
        ("Increase Font Size", "增大字体"),
        ("Decrease Font Size", "减小字体"),
        ("Command Palette", "命令面板"),
        ("Toggle Sidebar", "显示或隐藏侧边栏"),
        ("Toggle Inspector", "显示或隐藏检查器"),
        ("Change Tab Title...", "修改标签页标题…"),
        ("Change Terminal Title...", "修改终端标题…"),
        ("Terminal Read-only", "终端只读"),
        ("Quick Terminal", "快速终端"),
        ("Terminal Inspector", "终端检查器"),

        ("Window", "窗口"),
        ("Minimize", "最小化"),
        ("Zoom", "缩放"),
        ("Toggle Full Screen", "切换全屏"),
        ("Show/Hide All Terminals", "显示或隐藏所有终端"),
        ("Browse Sessions…", "浏览后台会话…"),
        ("Zoom Split", "缩放分屏"),
        ("Select Previous Split", "选择上一个分屏"),
        ("Select Next Split", "选择下一个分屏"),
        ("Select Split", "选择分屏"),
        ("Select Split Above", "选择上方分屏"),
        ("Select Split Below", "选择下方分屏"),
        ("Select Split Left", "选择左侧分屏"),
        ("Select Split Right", "选择右侧分屏"),
        ("Resize Split", "调整分屏"),
        ("Equalize Splits", "均分分屏"),
        ("Move Divider Up", "向上移动分隔线"),
        ("Move Divider Down", "向下移动分隔线"),
        ("Move Divider Left", "向左移动分隔线"),
        ("Move Divider Right", "向右移动分隔线"),
        ("Return To Default Size", "恢复默认大小"),
        ("Float on Top", "置于顶层"),
        ("Use as Default", "设为默认"),
        ("Bring All to Front", "全部置前"),

        ("Help", "帮助"),
        ("OMG Help", "OMG 帮助"),
    ]

    private static let englishByTitle: [String: String] = {
        var result: [String: String] = [:]
        for pair in titlePairs {
            result[pair.english] = pair.english
            result[pair.chinese] = pair.english
        }
        return result
    }()

    private static let chineseByEnglish = Dictionary(
        uniqueKeysWithValues: titlePairs.map { ($0.english, $0.chinese) }
    )

    static func apply(to menu: NSMenu?, strings: SettingsStrings) {
        guard let menu else { return }
        for item in menu.items {
            if let english = englishByTitle[item.title] {
                item.title = strings.isChinese
                    ? chineseByEnglish[english] ?? english
                    : english
            }
            if let submenu = item.submenu {
                apply(to: submenu, strings: strings)
            }
        }
    }
}
