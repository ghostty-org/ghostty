# Session-Surface Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable kanban board to manage Claude Code sessions linked to Ghostty terminal splits, with real-time status tracking via JSONL file watching.

**Architecture:** Hybrid WebView (HTML/CSS/JS) + Swift bridge. Sessions stored in `.ghostty/sessions.json`, real-time status from `~/.claude/projects/*/.jsonl` via FSEvents. Phase 3 adds Ghostty C API integration.

**Tech Stack:** Swift, WKWebView, FSEvents, JSONL parsing, C/Zig (Phase 3)

---

## Phase 1: Session Data Layer

### Task 1: Create SessionManager.swift

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/SessionManager.swift`

- [ ] **Step 1: Create SessionManager.swift with basic structure**

```swift
import Foundation

class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [Session] = []

    private let sessionsFileName = "sessions.json"

    private var sessionsFileURL: URL? {
        guard let configDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let ghosttyDir = configDir.appendingPathComponent("ghostty", isDirectory: true)
        return ghosttyDir.appendingPathComponent(sessionsFileName)
    }

    private init() {
        loadSessions()
    }

    func loadSessions() {
        guard let url = sessionsFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            sessions = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(SessionsWrapper.self, from: data)
            sessions = decoded.sessions
        } catch {
            print("[SessionManager] Failed to load sessions: \(error)")
            sessions = []
        }
    }

    func saveSessions() {
        guard let url = sessionsFileURL else { return }

        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let wrapper = SessionsWrapper(sessions: sessions)
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[SessionManager] Failed to save sessions: \(error)")
        }
    }

    func createSession(cwd: String, isWorktree: Bool, worktreeName: String?) -> Session {
        let session = Session(
            id: UUID(),
            title: "New Session",
            status: .running,
            timestamp: Date(),
            isWorkTree: isWorktree,
            branch: isWorktree ? (worktreeName ?? "main") : "main",
            sessionId: UUID().uuidString,
            surfaceId: nil,
            cwd: cwd
        )
        sessions.append(session)
        saveSessions()
        return session
    }

    func linkSessionToSurface(sessionId: UUID, surfaceId: UInt64) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].surfaceId = surfaceId
        saveSessions()
    }

    func unlinkSurface(surfaceId: UInt64) {
        guard let index = sessions.firstIndex(where: { $0.surfaceId == surfaceId }) else { return }
        sessions[index].surfaceId = nil
        saveSessions()
    }

    func updateSessionStatus(sessionId: UUID, status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].status = status
        saveSessions()
    }

    func deleteSession(sessionId: UUID) {
        sessions.removeAll { $0.id == sessionId }
        saveSessions()
    }

    func session(for sessionId: UUID) -> Session? {
        sessions.first { $0.id == sessionId }
    }
}

private struct SessionsWrapper: Codable {
    let sessions: [Session]
}
```

- [ ] **Step 2: Run build to verify compilation**

Run: `cd macos && xcodebuild -scheme Ghostty -configuration Debug build -quiet 2>&1 | grep -E "(error:|warning:|BUILD)"`

Expected: BUILD SUCCEEDED or only pre-existing warnings

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SessionManager.swift
git commit -m "feat(kanban): add SessionManager for session-surface mapping"
```

---

### Task 2: Extend Session model with sessionId and surfaceId

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/KanbanModels.swift:45-67`

- [ ] **Step 1: Update Session struct**

Find:
```swift
struct Session: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var status: SessionStatus
    var timestamp: Date
    var isWorkTree: Bool
    var branch: String

    init(id: UUID = UUID(), title: String, status: SessionStatus = .running, timestamp: Date = Date(), isWorkTree: Bool = false, branch: String = "main") {
        self.id = id
        self.title = title
        self.status = status
        self.timestamp = timestamp
        self.isWorkTree = isWorkTree
        self.branch = branch
    }
```

Replace with:
```swift
struct Session: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var status: SessionStatus
    var timestamp: Date
    var isWorkTree: Bool
    var branch: String
    var sessionId: String?      // Claude session UUID from JSONL
    var surfaceId: UInt64?      // Ghostty surface ID (nil if split closed)
    var cwd: String?

    init(id: UUID = UUID(), title: String, status: SessionStatus = .running, timestamp: Date = Date(), isWorkTree: Bool = false, branch: String = "main", sessionId: String? = nil, surfaceId: UInt64? = nil, cwd: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.timestamp = timestamp
        self.isWorkTree = isWorkTree
        self.branch = branch
        self.sessionId = sessionId
        self.surfaceId = surfaceId
        self.cwd = cwd
    }
```

- [ ] **Step 2: Run build to verify**

Run: `cd macos && xcodebuild -scheme Ghostty -configuration Debug build -quiet 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanModels.swift
git commit -m "feat(models): extend Session with sessionId, surfaceId, cwd"
```

---

### Task 3: Add session management methods to BoardState

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift`

- [ ] **Step 1: Read current BoardState.swift**

```swift
// Read the file to understand current structure
```

- [ ] **Step 2: Add session management methods**

Add these methods to the BoardState class:

```swift
func addSession(to taskId: UUID, session: Session) {
    guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
    tasks[index].sessions.append(session)
    saveTasks()
}

func removeSession(from taskId: UUID, sessionId: UUID) {
    guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }),
          let sessionIndex = tasks[taskIndex].sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    tasks[taskIndex].sessions.remove(at: sessionIndex)
    saveTasks()
}

func updateSessionStatus(taskId: UUID, sessionId: UUID, status: SessionStatus) {
    guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }),
          let sessionIndex = tasks[taskIndex].sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    tasks[taskIndex].sessions[sessionIndex].status = status
    saveTasks()
}
```

- [ ] **Step 3: Run build to verify**

Run: `cd macos && xcodebuild -scheme Ghostty -configuration Debug build -quiet 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift
git commit -m "feat(board): add session management methods to BoardState"
```

---

## Phase 2: JSONL Watching

### Task 4: Create SessionFileWatcher.swift

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/SessionFileWatcher.swift`

- [ ] **Step 1: Create SessionFileWatcher with FSEvents**

```swift
import Foundation

class SessionFileWatcher {
    private var stream: FSEventStreamRef?
    private var knownFiles: Set<String> = []
    private let sessionManager: SessionManager
    private let debounceInterval: TimeInterval = 0.2

    private var pendingUpdates: [String: Date] = [:]
    private var debounceTimer: Timer?

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        startWatching()
    }

    deinit {
        stopWatching()
    }

    func startWatching() {
        let paths = getClaudeProjectsPaths()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (
            streamRef,
            clientCallBackInfo,
            numEvents,
            eventPaths,
            eventFlags,
            eventIds
        ) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<SessionFileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            watcher.handleEvents(paths: paths)
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }

        // Initial scan
        scanAllFiles(paths: paths)
    }

    func stopWatching() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func getClaudeProjectsPaths() -> [String] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeProjectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard let contents = try? FileManager.default.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var jsonlFiles: [String] = []
        for projectDir in contents where projectDir.hasDirectoryURL {
            let jsonl = projectDir.appendingPathComponent("data.jsonl")
            if FileManager.default.fileExists(atPath: jsonl.path) {
                jsonlFiles.append(jsonl.path)
            }
        }

        return jsonlFiles
    }

    private func handleEvents(paths: [String]) {
        for path in paths {
            guard path.hasSuffix(".jsonl") else { continue }
            pendingUpdates[path] = Date()
        }

        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.processPendingUpdates()
        }
    }

    private func processPendingUpdates() {
        let paths = Array(pendingUpdates.keys)
        pendingUpdates.removeAll()
        scanAllFiles(paths: paths)
    }

    private func scanAllFiles(paths: [String]) {
        for path in paths {
            parseJSONL(at: path)
        }
    }

    private func parseJSONL(at path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var sessions: [ParsedSession] = []
        for line in lines {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            if let type = json["type"] as? String, type == "user" {
                let message = json["message"] as? [String: Any]
                let content = message?["content"] as? [[String: Any]]
                let textContent = content?.first(where: { $0["type"] as? String == "text" }) as? [String: Any]
                let text = textContent?["text"] as? String ?? ""

                let title = String(text.prefix(10))
                let sessionId = json["session_id"] as? String ?? UUID().uuidString

                sessions.append(ParsedSession(sessionId: sessionId, title: title))
            }
        }

        // Update sessionManager with parsed sessions
        DispatchQueue.main.async { [weak self] in
            self?.updateSessions(sessions: sessions, path: path)
        }
    }

    private func updateSessions(sessions: [ParsedSession], path: String) {
        for parsed in sessions {
            if let existing = sessionManager.sessions.first(where: { $0.sessionId == parsed.sessionId }) {
                // Update existing session
                sessionManager.updateSessionStatus(sessionId: existing.id, status: parsed.status)
            }
        }
    }
}

private struct ParsedSession {
    let sessionId: String
    let title: String
    var status: SessionStatus = .idle
}
```

- [ ] **Step 2: Run build to verify**

Run: `cd macos && xcodebuild -scheme Ghostty -configuration Debug build -quiet 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED (may have unused variable warnings)

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SessionFileWatcher.swift
git commit -m "feat(kanban): add SessionFileWatcher for JSONL monitoring"
```

---

### Task 5: Integrate SessionFileWatcher with app lifecycle

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift` (add watcher property)

- [ ] **Step 1: Add watcher to BoardState**

In KanbanBoardState, add:
```swift
private var sessionWatcher: SessionFileWatcher?
```

In BoardState.init, add:
```swift
sessionWatcher = SessionFileWatcher(sessionManager: SessionManager.shared)
```

- [ ] **Step 2: Run build to verify**

Run: `cd macos && xcodebuild -scheme Ghostty -configuration Debug build -quiet 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift
git commit -m "feat(board): integrate SessionFileWatcher with BoardState"
```

---

## Phase 3: WebView Message Bridge

### Task 6: Add new message handlers to KanbanWebView

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/KanbanWebView.swift:82-166`

- [ ] **Step 1: Add new message handler cases**

In the `userContentController` switch statement, add:

```swift
case "openSession":
    if let sessionId = body["sessionId"] as? String,
       let uuid = UUID(uuidString: sessionId) {
        SessionManager.shared.navigateToSession(id: uuid)
    }

case "createSessionAndLink":
    if let taskId = body["taskId"] as? String,
       let cwd = body["cwd"] as? String,
       let isWorkTree = body["isWorkTree"] as? Bool,
       let taskUUID = UUID(uuidString: taskId) {
        let worktreeName = body["worktreeName"] as? String
        let session = SessionManager.shared.createSession(
            cwd: cwd,
            isWorktree: isWorkTree,
            worktreeName: worktreeName
        )
        // Add session to task
        boardState.addSession(to: taskUUID, session: session)
        self.sendBoardState()
    }

case "unlinkSession":
    if let sessionId = body["sessionId"] as? String,
       let uuid = UUID(uuidString: sessionId) {
        SessionManager.shared.unlinkSession(id: uuid)
        self.sendBoardState()
    }

case "refreshSessions":
    SessionManager.shared.loadSessions()
    self.sendBoardState()
```

- [ ] **Step 2: Add navigateToSession to SessionManager**

In SessionManager.swift, add:
```swift
func navigateToSession(id: UUID) {
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    // Phase 3 will implement actual Ghostty surface creation
    print("[SessionManager] Navigate to session: \(session.title)")
}
```

- [ ] **Step 3: Add unlinkSession to SessionManager**

In SessionManager.swift, add:
```swift
func unlinkSession(id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    sessions[index].surfaceId = nil
    saveSessions()
}
```

- [ ] **Step 4: Run build to verify**

Run: `cd macos && xcodebuild -scheme Ghostty -configuration Debug build -quiet 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanWebView.swift macos/Sources/Ghostty/SidePanel/SessionManager.swift
git commit -m "feat(bridge): add session management message handlers"
```

---

### Task 7: Update board.html for session interactions

**Files:**
- Modify: `macos/Resources/Kanban/board.html`

- [ ] **Step 1: Update session-item click handler**

Find the session-item div and add onclick for opening session:

Change:
```html
<div class="session-item">
```

To:
```html
<div class="session-item" onclick="openSession('${task.id}', '${session.id}')" style="cursor: pointer;">
```

- [ ] **Step 2: Add openSession function**

In the `<script>` section, add:

```javascript
function openSession(taskId, sessionId) {
    window.webkit.messageHandlers.kanbanBridge.postMessage({
        type: "openSession",
        taskId: taskId,
        sessionId: sessionId
    });
}

function createSessionAndLink(taskId, cwd, isWorkTree, worktreeName) {
    window.webkit.messageHandlers.kanbanBridge.postMessage({
        type: "createSessionAndLink",
        taskId: taskId,
        cwd: cwd,
        isWorkTree: isWorkTree,
        worktreeName: worktreeName
    });
}

function unlinkSession(taskId, sessionId) {
    event.stopPropagation();
    window.webkit.messageHandlers.kanbanBridge.postMessage({
        type: "unlinkSession",
        taskId: taskId,
        sessionId: sessionId
    });
}
```

- [ ] **Step 3: Update addSession button**

Change the add-session-btn onclick to pass current directory:

```html
<button class="add-session-btn" onclick="promptForNewSession('${task.id}')">
```

Add the promptForNewSession function:

```javascript
function promptForNewSession(taskId) {
    const cwd = prompt("Enter working directory:", "/Users/hue");
    if (!cwd) return;

    const isWorkTree = confirm("Is this a worktree?");
    const worktreeName = isWorkTree ? prompt("Worktree name:") : null;

    createSessionAndLink(taskId, cwd, isWorkTree, worktreeName);
}
```

- [ ] **Step 4: Update removeSession to use new unlinkSession**

Change removeSession function:

```javascript
function removeSession(taskId, sessionId) {
    event.stopPropagation();
    if (confirm('Remove this session?')) {
        window.webkit.messageHandlers.kanbanBridge.postMessage({
            type: "removeSession",
            taskId: taskId,
            sessionId: sessionId
        });
    }
}
```

- [ ] **Step 5: Test locally**

Open the app and verify:
- Session items are clickable
- Add session prompts for cwd/worktree info
- Remove session confirms before removing

- [ ] **Step 6: Commit**

```bash
git add macos/Resources/Kanban/board.html
git commit -m "feat(ui): add session interaction handlers to board.html"
```

---

## Phase 4: Ghostty C API Integration (Optional/Future)

### Task 8: Ghostty C API Extensions

**Note:** This task requires modifying Ghostty itself. May need to be done in a separate branch or fork.

- [ ] **Step 1: Add C API declarations to ghostty.h**

Add to `include/ghostty.h`:
```c
uint64_t ghostty_surface_split_with_command(
    void *surface_ptr,
    int direction,
    const char *command,
    const char *cwd,
    const char *title
);

void ghostty_surface_text(void *surface_ptr, const char *text, size_t len);
uint64_t ghostty_surface_get_id(void *surface_ptr);
void ghostty_app_focus_surface(void *app_ptr, uint64_t surface_id);
```

- [ ] **Step 2: Implement in Zig**

Add to `src/apprt/embedded.zig`:
```zig
pub extern "c" fn ghostty_surface_split_with_command(
    surface: *anyopaque,
    direction: c_int,
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    title: ?[*:0]const u8
) callconv(.C) u64 {
    // Implementation
}

pub extern "c" fn ghostty_surface_text(
    surface: *anyopaque,
    text: ?[*]const u8,
    len: usize
) callconv(.C) void {
    // Implementation
}

// ... etc
```

- [ ] **Step 3: Swift import**

In a new `GhosttyBridge.swift`:
```swift
import Foundation

@_silgen_name("ghostty_surface_split_with_command")
func ghostty_surface_split_with_command(
    _ surface: UnsafeRawPointer,
    _ direction: Int32,
    _ command: UnsafePointer<CChar>?,
    _ cwd: UnsafePointer<CChar>?,
    _ title: UnsafePointer<CChar>?
) -> UInt64
```

- [ ] **Step 4: Wire up SessionManager.navigateToSession**

Implement actual Ghostty split creation in SessionManager.

---

## Summary

| Phase | Tasks | Files Created/Modified |
|-------|-------|------------------------|
| 1 | 1-3 | SessionManager.swift (new), KanbanModels.swift (mod), KanbanBoardState.swift (mod) |
| 2 | 4-5 | SessionFileWatcher.swift (new), KanbanBoardState.swift (mod) |
| 3 | 6-7 | KanbanWebView.swift (mod), SessionManager.swift (mod), board.html (mod) |
| 4 | 8 | ghostty.h, embedded.zig, GhosttyBridge.swift (new) |
