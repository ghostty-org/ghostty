import Foundation

struct AgentHistoryStrings: Equatable, Sendable {
    private let settings: SettingsStrings

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.settings = SettingsStrings(
            language: language,
            preferredLanguages: preferredLanguages
        )
    }

    @MainActor static var current: Self {
        .init(language: OhMyGhosttySettings.shared.language)
    }

    private func t(_ english: String, _ chinese: String) -> String {
        settings.isChinese ? chinese : english
    }

    var title: String { t("Agent History", "Agent 历史") }
    var allAgents: String { t("All Agents", "全部 Agent") }
    var searchPlaceholder: String { t("Search sessions", "搜索会话") }
    var organize: String { t("Filter & Organize", "筛选与整理") }
    var filterSection: String { t("Filter", "筛选") }
    var directorySection: String { t("Folder", "目录") }
    var directoryCurrent: String { t("This Folder", "当前目录") }
    var directoryUnavailable: String { t("Current folder unavailable", "当前目录不可用") }
    var timeSection: String { t("Time", "时间") }
    var anyOption: String { t("All", "全部") }
    var timeDay: String { t("24h", "24 小时") }
    var timeWeek: String { t("7d", "7 天") }
    var timeMonth: String { t("30d", "30 天") }
    var timeQuarter: String { t("3mo", "3 个月") }
    var timeYear: String { t("1y", "1 年") }
    var filterActive: String { t("Filtered", "已筛选") }
    var reset: String { t("Reset", "重置") }
    var groupSection: String { t("GROUP", "分组") }
    var orderSection: String { t("ORDER", "排序") }
    var groupNone: String { t("No Grouping", "不分组") }
    var groupProject: String { t("By Project", "按项目/目录") }
    var groupAgent: String { t("By Agent", "按 Agent") }
    var groupDate: String { t("By Date", "按日期") }
    var orderRecentlyUpdated: String { t("Recently Updated", "最近更新") }
    var orderTitle: String { t("Title", "会话标题") }
    var today: String { t("Today", "今天") }
    var yesterday: String { t("Yesterday", "昨天") }
    var copyMessage: String { t("Copy Message", "复制内容") }
    var copyResumeCommand: String { t("Copy Resume Command", "复制恢复命令") }
    var copied: String { t("Copied", "已复制") }
    var forkSession: String { t("Fork in New Tab", "分叉到新标签页") }
    var noSessions: String { t("No Agent Sessions", "暂无 Agent 会话") }
    var noSessionsMessage: String {
        t(
            "Recent local sessions from Agents with verified resume support appear here.",
            "支持安全恢复的 Agent 本地会话会显示在这里。"
        )
    }
    var searchingSessions: String { t("Searching Sessions…", "正在搜索会话…") }
    var searchingSessionsMessage: String {
        t(
            "Title results appear first. Complete transcript matches continue loading in the background.",
            "标题结果会优先显示，完整正文匹配仍在后台继续加载。"
        )
    }
    var noMatches: String { t("No Matching Sessions", "没有匹配的会话") }
    var noMatchesMessage: String {
        t("Try another Agent, group, or search term.", "请尝试其他 Agent、分组或搜索词。")
    }
    var loading: String { t("Loading Agent history…", "正在加载 Agent 历史…") }
    var loadingTranscript: String { t("Loading transcript…", "正在加载会话记录…") }
    var emptyTranscript: String { t("No readable messages", "没有可读消息") }
    var emptyTranscriptMessage: String {
        t(
            "This session can still be resumed, but its current log format has no readable user or assistant messages.",
            "仍可恢复此会话，但当前日志格式中没有可读的用户或 Agent 消息。"
        )
    }
    var resume: String { t("Resume", "恢复") }
    var openLive: String { t("Open Live", "进入运行中会话") }
    var live: String { t("Live", "运行中") }
    var refresh: String { t("Refresh Agent History", "刷新 Agent 历史") }
    var back: String { t("Back to Agent History", "返回 Agent 历史") }
    var you: String { t("You", "你") }
    var searchTranscriptPlaceholder: String { t("Find in transcript (⌘F)", "在会话中搜索 (⌘F)") }
    var matchesCount: String { t("matches", "条匹配") }
    func loadMoreMessages(_ remaining: Int) -> String {
        t("Load more (\(remaining) remaining)…", "加载更多 (剩余 \(remaining) 条)…")
    }
    func loadMoreSessions(_ remaining: Int) -> String {
        t("Load more sessions (\(remaining) remaining)…", "加载更多会话 (剩余 \(remaining) 个)…")
    }
    var truncated: String {
        t(
            "This long transcript was truncated to keep the Inspector responsive.",
            "为保持 Inspector 流畅，此超长会话记录已截断。"
        )
    }

    func sessionCount(_ count: Int) -> String {
        t("\(count) sessions", "\(count) 个会话")
    }

    func remoteSessionCount(_ count: Int, host: String) -> String {
        t("\(host): \(count) sessions", "\(host)：\(count) 个会话")
    }

    func relativeTime(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return t("Just now", "刚刚") }
        if seconds < 3_600 {
            let minutes = max(1, Int(seconds / 60))
            return t("\(minutes) min ago", "\(minutes) 分钟前")
        }
        if seconds < 86_400 {
            let hours = max(1, Int(seconds / 3_600))
            return t("\(hours) hr ago", "\(hours) 小时前")
        }
        let days = max(1, Int(seconds / 86_400))
        return t("\(days) days ago", "\(days) 天前")
    }
}
