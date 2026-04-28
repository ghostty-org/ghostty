# Kanban Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS sidebar kanban board to Ghostty terminal emulator with multi-project support, drag-and-drop cards, session/split management, and JSON persistence.

**Architecture:** SwiftUI-based sidebar integrated into Ghostty's macOS window via NavigationSplitView. Zig core handles data types and persistence. Platform abstraction layer (apprt) provides split/terminal interface. Four-column kanban (Todo/In Progress/Review/Done) with color-coded priority badges and expandable session lists.

**Tech Stack:** SwiftUI (macOS), Zig (core + persistence), C API (ghostty.h), JSON (tasks.json)

---

## File Structure

```
macos/Sources/Ghostty/SidePanel/
├── SidePanelView.swift          # Main container, project tabs + kanban board
├── KanbanColumn.swift           # Single status column (Todo/In Progress/Review/Done)
├── CardView.swift               # Task card with priority strip, sessions
├── SessionRowView.swift         # Single session in expanded card
├── AddSessionSheet.swift        # Sheet to add new session to card
├── CardEditSheet.swift          # Sheet to edit card title/description/priority
├── SidePanelViewModel.swift     # ObservableObject: state, persistence, terminal bridge
└── Models.swift                 # Swift Codable models: Project, Card, Session, etc.

src/task/
├── types.zig                   # Zig data types: CardStatus, Priority, Session, Card, Project
└── store.zig                   # JSON persistence: load/save projects to tasks.json

src/apprt/
└── sidepanel.zig               # Platform interface: create_split, focus_split, run_command

src/config/
└── Config.zig                  # Add: sidebar_kanban_enabled, sidebar_kanban_width

macos/Sources/Ghostty/
├── Ghostty.Config.swift         # Wrap new config options for Swift access
└── (other files to modify for integration)

Tests:
test/task/                       # Zig tests for store.zig types and persistence
```

---

## Task 1: Zig Data Types

**Files:**
- Create: `src/task/types.zig`
- Test: `test/task/types_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const types = @import("types.zig");

test "CardStatus enum has all four states" {
    try std.testing.expectEqual(@as(u8, 4), @typeInfo(types.CardStatus).Enum.fields.len);
    try std.testing.expectEqual(types.CardStatus.todo, types.CardStatus.todo);
    try std.testing.expectEqual(types.CardStatus.in_progress, types.CardStatus.in_progress);
    try std.testing.expectEqual(types.CardStatus.review, types.CardStatus.review);
    try std.testing.expectEqual(types.CardStatus.done, types.CardStatus.done);
}

test "Priority enum ordered correctly" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(types.Priority.p0));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(types.Priority.p1));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(types.Priority.p2));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(types.Priority.p3));
}

test "Session struct fields" {
    const session = types.Session{
        .id = "s1",
        .name = "Test Session",
        .cwd = "/tmp",
        .command = "echo hello",
        .split_id = null,
        .is_worktree = false,
        .worktree_name = null,
    };
    try std.testing.expectEqualStrings("s1", session.id);
    try std.testing.expectEqualStrings("Test Session", session.name);
    try std.testing.expectEqualStrings("/tmp", session.cwd);
    try std.testing.expectEqualStrings("echo hello", session.command);
    try std.testing.expectEqual(false, session.is_worktree);
}

test "Card struct with sessions" {
    var session = types.Session{
        .id = "s1",
        .name = "Session 1",
        .cwd = "/home",
        .command = "ls",
        .split_id = null,
        .is_worktree = false,
        .worktree_name = null,
    };
    const card = types.Card{
        .id = "c1",
        .title = "My Task",
        .description = "Description here",
        .status = .todo,
        .priority = .p1,
        .sessions = &.{session},
    };
    try std.testing.expectEqualStrings("c1", card.id);
    try std.testing.expectEqualStrings("My Task", card.title);
    try std.testing.expectEqual(types.CardStatus.todo, card.status);
    try std.testing.expectEqual(types.Priority.p1, card.priority);
    try std.testing.expectEqual(@as(usize, 1), card.sessions.len);
}

test "Project struct with cards" {
    const card = types.Card{
        .id = "c1",
        .title = "Task 1",
        .description = "",
        .status = .todo,
        .priority = .p2,
        .sessions = &.{},
    };
    const project = types.Project{
        .id = "p1",
        .name = "My Project",
        .cards = &.{card},
    };
    try std.testing.expectEqualStrings("p1", project.id);
    try std.testing.expectEqualStrings("My Project", project.name);
    try std.testing.expectEqual(@as(usize, 1), project.cards.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/task/types.zig`
Expected: FAIL - file does not exist

- [ ] **Step 3: Write minimal types.zig implementation**

```zig
const std = @import("std");

pub const CardStatus = enum(u2) {
    todo = 0,
    in_progress = 1,
    review = 2,
    done = 3,
};

pub const Priority = enum(u2) {
    p0 = 0, // Critical
    p1 = 1, // High
    p2 = 2, // Medium
    p3 = 3, // Low
};

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    cwd: []const u8,
    command: []const u8,
    split_id: ?[]const u8 = null,
    is_worktree: bool = false,
    worktree_name: ?[]const u8 = null,
};

pub const Card = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    status: CardStatus = .todo,
    priority: Priority = .p2,
    sessions: []const Session = &.{},
};

pub const Project = struct {
    id: []const u8,
    name: []const u8,
    cards: []const Card = &.{},
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/task/types.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/task/types.zig test/task/types_test.zig
git commit -m "feat(kanban): add Zig data types for Card, Project, Session"
```

---

## Task 2: JSON Persistence Store

**Files:**
- Create: `src/task/store.zig`
- Test: `test/task/store_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const store = @import("store.zig");
const types = @import("types.zig");

test "store.load returns empty slice when file missing" {
    const allocator = std.testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const path = try std.fmt.allocPrint(allocator, "{s}/nonexistent.json", .{tmp_dir.dir.id});
    defer allocator.free(path);
    
    const projects = store.load(path);
    defer store.freeProjects(projects, allocator);
    try std.testing.expectEqual(@as(usize, 0), projects.len);
}

test "store.save and load roundtrip" {
    const allocator = std.testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const path = try std.fmt.allocPrint(allocator, "{s}/tasks.json", .{tmp_dir.dir.id});
    defer allocator.free(path);
    
    const project = types.Project{
        .id = "p1",
        .name = "Test Project",
        .cards = &.{
            types.Card{
                .id = "c1",
                .title = "Test Card",
                .description = "A test",
                .status = .todo,
                .priority = .p1,
                .sessions = &.{},
            },
        },
    };
    
    try store.save(&.{project}, path);
    const loaded = try store.loadAlloc(path, allocator);
    defer store.freeProjects(loaded, allocator);
    
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("p1", loaded[0].id);
    try std.testing.expectEqualStrings("Test Project", loaded[0].name);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].cards.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/task/store.zig`
Expected: FAIL - file does not exist

- [ ] **Step 3: Write minimal store.zig implementation**

```zig
const std = @import("std");
const types = @import("types.zig");

pub fn load(path: []const u8) []const types.Project {
    return &.{};
}

pub fn save(projects: []const types.Project, path: []const u8) !void {
    var file = try std.fs.createFile(path, .{});
    defer file.close();
    try file.writeAll("[]");
}

pub fn loadAlloc(path: []const u8, allocator: std.mem.Allocator) ![]const types.Project {
    return &.{};
}

pub fn freeProjects(projects: []const types.Project, allocator: std.mem.Allocator) void {
    _ = projects;
    _ = allocator;
}
```

- [ ] **Step 4: Run test to verify it fails differently**

Run: `zig test src/task/store.zig`
Expected: FAIL - "nonexistent.json" not found (for first test) or assertion failed (for second - file empty)

- [ ] **Step 5: Write actual JSON persistence implementation**

```zig
const std = @import("std");
const types = @import("types.zig");

pub fn load(path: []const u8) []const types.Project {
    const file = std.fs.openFileAbsolute(path, .{}) catch return &.{};
    defer file.close();
    
    const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return &.{};
    defer std.heap.page_allocator.free(content);
    
    return parseProjects(content) catch return &.{};
}

pub fn save(projects: []const types.Project, path: []const u8) !void {
    var file = try std.fs.createFile(path, .{});
    defer file.close();
    
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try serializeProjects(projects, fbs.writer());
    try file.writeAll(fbs.getWritten());
}

fn parseProjects(content: []const u8) ![]const types.Project {
    // Minimal JSON parsing - iterate and extract project objects
    _ = content;
    return &.{};
}

fn serializeProjects(projects: []const types.Project, writer: anytype) !void {
    try writer.writeAll("[]");
}
```

- [ ] **Step 6: Run test - still failing, implement proper JSON**

Run: `zig test src/task/store.zig`
Expected: FAIL - need full JSON implementation

- [ ] **Step 7: Write full JSON implementation using std.json**

```zig
const std = @import("std");
const types = @import("types.zig");
const json = std.json;

pub fn load(path: []const u8) []const types.Project {
    const file = std.fs.openFileAbsolute(path, .{}) catch return &.{};
    defer file.close();
    
    const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return &.{};
    defer std.heap.page_allocator.free(content);
    
    return loadFromSlice(content) catch return &.{};
}

pub fn loadFromSlice(content: []const u8) ![]const types.Project {
    var parser = json.Parser.init(std.heap.page_allocator, .{});
    defer parser.deinit();
    
    const parsed = try parser.parse(content);
    const array = parsed.root.array;
    
    var projects = std.heap.page_allocator.alloc(types.Project, array.len) catch return &.{};
    errdefer std.heap.page_allocator.free(projects);
    
    for (array.items, 0..) |item, i| {
        projects[i] = try parseProject(item);
    }
    
    return projects;
}

fn parseProject(item: json.Value) !types.Project {
    const obj = item.object;
    const id = obj.get("id").?.string;
    const name = obj.get("name").?.string;
    
    var cards: []types.Card = &.{};
    if (obj.get("cards")) |cards_val| {
        cards = try parseCards(cards_val.array);
    }
    
    return types.Project{
        .id = id,
        .name = name,
        .cards = cards,
    };
}

fn parseCards(items: []json.Value) ![]types.Card {
    var cards = std.heap.page_allocator.alloc(types.Card, items.len) catch return &.{};
    for (items, 0..) |item, i| {
        cards[i] = try parseCard(item);
    }
    return cards;
}

fn parseCard(item: json.Value) !types.Card {
    const obj = item.object;
    return types.Card{
        .id = obj.get("id").?.string,
        .title = obj.get("title").?.string,
        .description = obj.get("description").?.string,
        .status = try parseStatus(obj.get("status").?.string),
        .priority = try parsePriority(obj.get("priority").?.string),
        .sessions = &.{},
    };
}

fn parseStatus(s: []const u8) !types.CardStatus {
    if (std.mem.eql(u8, s, "todo")) return .todo;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, s, "review")) return .review;
    if (std.mem.eql(u8, s, "done")) return .done;
    return error.InvalidStatus;
}

fn parsePriority(s: []const u8) !types.Priority {
    if (std.mem.eql(u8, s, "p0")) return .p0;
    if (std.mem.eql(u8, s, "p1")) return .p1;
    if (std.mem.eql(u8, s, "p2")) return .p2;
    if (std.mem.eql(u8, s, "p3")) return .p3;
    return error.InvalidPriority;
}

pub fn save(projects: []const types.Project, path: []const u8) !void {
    var file = try std.fs.createFile(path, .{});
    defer file.close();
    
    try file.writeAll("[\n");
    for (projects, 0..) |project, pi| {
        try serializeProject(file.writer(), project);
        if (pi < projects.len - 1) try file.writeAll(",");
        try file.writeAll("\n");
    }
    try file.writeAll("]\n");
}

fn serializeProject(writer: anytype, project: types.Project) !void {
    try writer.print(
        \\  {{"id":"{s}","name":"{s}","cards":[
    , .{project.id, project.name});
    
    for (project.cards, 0..) |card, ci| {
        try serializeCard(writer, card);
        if (ci < project.cards.len - 1) try writer.writeAll(",");
    }
    
    try writer.writeAll("]}");
}

fn serializeCard(writer: anytype, card: types.Card) !void {
    const status_str = switch (card.status) {
        .todo => "todo",
        .in_progress => "in_progress",
        .review => "review",
        .done => "done",
    };
    const priority_str = switch (card.priority) {
        .p0 => "p0",
        .p1 => "p1",
        .p2 => "p2",
        .p3 => "p3",
    };
    try writer.print(
        \\    {{"id":"{s}","title":"{s}","description":"{s}","status":"{s}","priority":"{s}","sessions":[]}}
    , .{card.id, card.title, card.description, status_str, priority_str});
}

pub fn freeProjects(projects: []const types.Project, allocator: std.mem.Allocator) void {
    for (projects) |project| {
        allocator.free(project.cards);
    }
    allocator.free(projects);
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `zig test src/task/store.zig`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add src/task/store.zig test/task/store_test.zig
git commit -m "feat(kanban): add JSON persistence for projects and cards"
```

---

## Task 3: Config Options

**Files:**
- Modify: `src/config/Config.zig` (add sidebar_kanban_enabled, sidebar_kanban_width)
- Modify: `include/ghostty.h` (add config field if needed)

- [ ] **Step 1: Write the failing test**

Find a test file for Config.zig and add:
```zig
test "Config has sidebar_kanban fields" {
    const config = try parseConfigLine("sidebar-kanban-enabled = true");
    try std.testing.expectEqual(true, config.sidebar_kanban_enabled);
}
```

Run: `zig test src/config/Config.zig`
Expected: FAIL - field doesn't exist

- [ ] **Step 2: Add fields to Config struct**

In `src/config/Config.zig`, find the config struct and add:
```zig
sidebar_kanban_enabled: bool = false,
sidebar_kanban_width: u32 = 280,
```

- [ ] **Step 3: Run test to verify it passes**

Run: `zig test src/config/Config.zig`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat(kanban): add sidebar-kanban-enabled and sidebar-kanban-width config options"
```

---

## Task 4: Swift Models

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/Models.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class ModelsTests: XCTestCase {
    func testCardStatusAllCases() {
        XCTAssertEqual(CardStatus.allCases.count, 4)
        XCTAssertEqual(CardStatus.todo.rawValue, "todo")
        XCTAssertEqual(CardStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(CardStatus.review.rawValue, "review")
        XCTAssertEqual(CardStatus.done.rawValue, "done")
    }
    
    func testPriorityOrdering() {
        XCTAssertEqual(Priority.p0.rawValue, 0)
        XCTAssertEqual(Priority.p1.rawValue, 1)
        XCTAssertEqual(Priority.p2.rawValue, 2)
        XCTAssertEqual(Priority.p3.rawValue, 3)
    }
    
    func testSessionCodable() throws {
        let session = Session(
            id: "s1",
            name: "Test",
            cwd: "/tmp",
            command: "ls",
            splitId: nil,
            isWorktree: false,
            worktreeName: nil
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session.id, decoded.id)
        XCTAssertEqual(session.name, decoded.name)
    }
    
    func testCardCodable() throws {
        let card = Card(
            id: "c1",
            title: "Task",
            description: "Desc",
            status: .todo,
            priority: .p1,
            sessions: []
        )
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(Card.self, from: data)
        XCTAssertEqual(card.id, decoded.id)
        XCTAssertEqual(card.title, decoded.title)
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter ModelsTests`
Expected: FAIL - Models.swift doesn't exist

- [ ] **Step 3: Write Models.swift**

```swift
import Foundation

enum CardStatus: String, Codable, CaseIterable {
    case todo = "todo"
    case inProgress = "in_progress"
    case review = "review"
    case done = "done"
    
    var title: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
    
    var color: String {
        switch self {
        case .todo: return "accent"
        case .inProgress: return "warning"
        case .review: return "worktree"
        case .done: return "success"
        }
    }
}

enum Priority: Int, Codable, CaseIterable {
    case p0 = 0
    case p1 = 1
    case p2 = 2
    case p3 = 3
    
    var title: String {
        switch self {
        case .p0: return "P0"
        case .p1: return "P1"
        case .p2: return "P2"
        case .p3: return "P3"
        }
    }
    
    var color: String {
        switch self {
        case .p0: return "danger"
        case .p1: return "warning"
        case .p2: return "secondary"
        case .p3: return "muted"
        }
    }
}

struct Session: Codable, Identifiable {
    let id: String
    var name: String
    var cwd: String
    var command: String
    var splitId: String?
    var isWorktree: Bool
    var worktreeName: String?
    
    init(id: String = UUID().uuidString, name: String, cwd: String, command: String, splitId: String? = nil, isWorktree: Bool = false, worktreeName: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.splitId = splitId
        self.isWorktree = isWorktree
        self.worktreeName = worktreeName
    }
}

struct Card: Codable, Identifiable {
    let id: String
    var title: String
    var description: String
    var status: CardStatus
    var priority: Priority
    var sessions: [Session]
    var isExpanded: Bool = false
    
    init(id: String = UUID().uuidString, title: String, description: String = "", status: CardStatus = .todo, priority: Priority = .p2, sessions: [Session] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.sessions = sessions
    }
}

struct Project: Codable, Identifiable {
    let id: String
    var name: String
    var cards: [Card]
    
    init(id: String = UUID().uuidString, name: String, cards: [Card] = []) {
        self.id = id
        self.name = name
        self.cards = cards
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/Models.swift
git commit -m "feat(kanban): add Swift Codable models for Card, Session, Project"
```

---

## Task 5: SidePanelViewModel

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/SidePanelViewModel.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class SidePanelViewModelTests: XCTestCase {
    func testViewModelInitializesWithEmptyProjects() {
        let vm = SidePanelViewModel()
        XCTAssertEqual(vm.projects.count, 0)
        XCTAssertFalse(vm.isVisible)
    }
    
    func testAddProject() {
        let vm = SidePanelViewModel()
        vm.addProject(name: "Test Project")
        XCTAssertEqual(vm.projects.count, 1)
        XCTAssertEqual(vm.projects[0].name, "Test Project")
    }
    
    func testSelectProject() {
        let vm = SidePanelViewModel()
        vm.addProject(name: "Project 1")
        vm.addProject(name: "Project 2")
        vm.selectProject(at: 1)
        XCTAssertEqual(vm.currentProject?.id, vm.projects[1].id)
    }
    
    func testAddCardToCurrentProject() {
        let vm = SidePanelViewModel()
        vm.addProject(name: "My Project")
        vm.addCard(title: "New Card", description: "Test desc", priority: .p1)
        XCTAssertEqual(vm.currentProject?.cards.count, 1)
        XCTAssertEqual(vm.currentProject?.cards[0].title, "New Card")
    }
    
    func testMoveCard() {
        let vm = SidePanelViewModel()
        vm.addProject(name: "Project")
        vm.addCard(title: "Card 1", priority: .p2)
        guard let cardId = vm.currentProject?.cards[0].id else { return }
        vm.moveCard(id: cardId, to: .inProgress)
        XCTAssertEqual(vm.currentProject?.cards[0].status, .inProgress)
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter SidePanelViewModelTests`
Expected: FAIL - SidePanelViewModel doesn't exist

- [ ] **Step 3: Write SidePanelViewModel.swift**

```swift
import Foundation
import SwiftUI
import Combine

@MainActor
final class SidePanelViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var currentProjectIndex: Int = 0
    @Published var isVisible: Bool = true
    
    private let path: URL
    
    var currentProject: Project? {
        guard currentProjectIndex >= 0 && currentProjectIndex < projects.count else { return nil }
        return projects[currentProjectIndex]
    }
    
    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.path = configDir.appendingPathComponent("tasks.json")
        load()
    }
    
    func load() {
        guard FileManager.default.fileExists(atPath: path.path) else {
            projects = [Project(name: "Default")]
            return
        }
        do {
            let data = try Data(contentsOf: path)
            projects = try JSONDecoder().decode([Project].self, from: data)
            if projects.isEmpty {
                projects = [Project(name: "Default")]
            }
        } catch {
            projects = [Project(name: "Default")]
        }
    }
    
    func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: path)
        } catch {
            print("Failed to save: \(error)")
        }
    }
    
    func addProject(name: String) {
        let project = Project(name: name)
        projects.append(project)
        currentProjectIndex = projects.count - 1
        save()
    }
    
    func deleteProject(at index: Int) {
        guard projects.count > 1 else { return }
        projects.remove(at: index)
        if currentProjectIndex >= projects.count {
            currentProjectIndex = projects.count - 1
        }
        save()
    }
    
    func selectProject(at index: Int) {
        guard index >= 0 && index < projects.count else { return }
        currentProjectIndex = index
    }
    
    func addCard(title: String, description: String = "", priority: Priority = .p2, status: CardStatus = .todo) {
        guard currentProjectIndex < projects.count else { return }
        let card = Card(title: title, description: description, status: status, priority: priority)
        projects[currentProjectIndex].cards.append(card)
        save()
    }
    
    func updateCard(_ card: Card) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == card.id }) {
            projects[currentProjectIndex].cards[idx] = card
            save()
        }
    }
    
    func deleteCard(id: String) {
        guard currentProjectIndex < projects.count else { return }
        projects[currentProjectIndex].cards.removeAll { $0.id == id }
        save()
    }
    
    func moveCard(id: String, to status: CardStatus) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == id }) {
            projects[currentProjectIndex].cards[idx].status = status
            save()
        }
    }
    
    func addSession(to cardId: String, session: Session) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == cardId }) {
            projects[currentProjectIndex].cards[idx].sessions.append(session)
            save()
        }
    }
    
    func deleteSession(cardId: String, sessionId: String) {
        guard currentProjectIndex < projects.count else { return }
        if let cardIdx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == cardId }) {
            projects[currentProjectIndex].cards[cardIdx].sessions.removeAll { $0.id == sessionId }
            save()
        }
    }
    
    func toggleCardExpanded(_ cardId: String) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == cardId }) {
            projects[currentProjectIndex].cards[idx].isExpanded.toggle()
        }
    }
}
```

- [ ] **Step 4: Run test - should still fail (test needs updating)**

Run: `swift test --filter SidePanelViewModelTests`
Expected: FAIL - path issues

- [ ] **Step 5: Fix tests to work with file system**

The tests will fail because path handling needs adjustment. Update tests to mock or use temp directory.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter SidePanelViewModelTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SidePanelViewModel.swift
git commit -m "feat(kanban): add SidePanelViewModel with project/card/session management"
```

---

## Task 6: KanbanColumn View

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/KanbanColumn.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class KanbanColumnTests: XCTestCase {
    func testKanbanColumnRendersTitle() {
        let column = KanbanColumn(status: .todo, cards: [], viewModel: SidePanelViewModel())
        let text = column.body.toString()
        XCTAssertTrue(text.contains("Todo"))
    }
    
    func testKanbanColumnShowsCardCount() {
        let card = Card(title: "Test", status: .todo, priority: .p2)
        let column = KanbanColumn(status: .todo, cards: [card], viewModel: SidePanelViewModel())
        let text = column.body.toString()
        XCTAssertTrue(text.contains("1"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter KanbanColumnTests`
Expected: FAIL - KanbanColumn doesn't exist

- [ ] **Step 3: Write KanbanColumn.swift**

```swift
import SwiftUI

struct KanbanColumn: View {
    let status: CardStatus
    let cards: [Card]
    @ObservedObject var viewModel: SidePanelViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(status.title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(cards.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        CardView(card: card, viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .dropDestination(for: String.self) { cardIds, _ in
            for cardId in cardIds {
                viewModel.moveCard(id: cardId, to: status)
            }
            return true
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .todo: return .blue
        case .inProgress: return .orange
        case .review: return .purple
        case .done: return .green
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KanbanColumnTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanColumn.swift
git commit -m "feat(kanban): add KanbanColumn view for kanban board columns"
```

---

## Task 7: CardView

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/CardView.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class CardViewTests: XCTestCase {
    func testCardViewShowsTitle() {
        let card = Card(title: "My Task", status: .todo, priority: .p1)
        let view = CardView(card: card, viewModel: SidePanelViewModel())
        let text = view.body.toString()
        XCTAssertTrue(text.contains("My Task"))
    }
    
    func testCardViewShowsPriorityBadge() {
        let card = Card(title: "P0 Task", status: .todo, priority: .p0)
        let view = CardView(card: card, viewModel: SidePanelViewModel())
        let text = view.body.toString()
        XCTAssertTrue(text.contains("P0"))
    }
    
    func testCardViewShowsSessionCount() {
        var card = Card(title: "Task with Sessions", status: .todo, priority: .p2)
        card.sessions = [Session(name: "S1", cwd: "/", command: "ls")]
        let view = CardView(card: card, viewModel: SidePanelViewModel())
        let text = view.body.toString()
        XCTAssertTrue(text.contains("1"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter CardViewTests`
Expected: FAIL - CardView doesn't exist

- [ ] **Step 3: Write CardView.swift**

```swift
import SwiftUI

struct CardView: View {
    let card: Card
    @ObservedObject var viewModel: SidePanelViewModel
    
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            priorityStrip
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                    if !card.sessions.isEmpty {
                        Button(action: { withAnimation { isExpanded.toggle() } }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if !card.description.isEmpty {
                    Text(card.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                HStack(spacing: 8) {
                    priorityBadge
                    
                    if !card.sessions.isEmpty {
                        sessionCountBadge
                    }
                }
            }
            .padding(12)
            
            if !card.sessions.isEmpty && isExpanded {
                Divider()
                sessionsList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .draggable(card.id) {
            Text(card.id)
                .padding(8)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(4)
        }
    }
    
    private var priorityStrip: some View {
        Rectangle()
            .fill(priorityColor)
            .frame(height: 4)
    }
    
    private var priorityBadge: some View {
        Text(card.priority.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(priorityColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor.opacity(0.15))
            .cornerRadius(4)
    }
    
    private var sessionCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.split.bottomrightquarter")
                .font(.system(size: 10))
            Text("\(card.sessions.count)")
                .font(.system(size: 10))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(4)
    }
    
    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.sessions) { session in
                SessionRowView(session: session, cardId: card.id, viewModel: viewModel)
                if session.id != card.sessions.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    private var priorityColor: Color {
        switch card.priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .yellow
        case .p3: return .gray
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/CardView.swift
git commit -m "feat(kanban): add CardView with priority strip, badges, and expandable sessions"
```

---

## Task 8: SessionRowView

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/SessionRowView.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class SessionRowViewTests: XCTestCase {
    func testSessionRowShowsName() {
        let session = Session(name: "Claude", cwd: "/home", command: "claude --resume")
        let view = SessionRowView(session: session, cardId: "c1", viewModel: SidePanelViewModel())
        let text = view.body.toString()
        XCTAssertTrue(text.contains("Claude"))
    }
    
    func testSessionRowShowsWorktreeBadge() {
        let session = Session(name: "Feature", cwd: "/home", command: "ls", isWorktree: true, worktreeName: "feature-branch")
        let view = SessionRowView(session: session, cardId: "c1", viewModel: SidePanelViewModel())
        let text = view.body.toString()
        XCTAssertTrue(text.contains("worktree"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter SessionRowViewTests`
Expected: FAIL - SessionRowView doesn't exist

- [ ] **Step 3: Write SessionRowView.swift**

```swift
import SwiftUI

struct SessionRowView: View {
    let session: Session
    let cardId: String
    @ObservedObject var viewModel: SidePanelViewModel
    
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sessionColor)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }
            
            if session.isWorktree {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.branch")
                        .font(.system(size: 9))
                    Text(session.worktreeName ?? "worktree")
                        .font(.system(size: 10))
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.15))
                .cornerRadius(4)
            }
            
            Spacer()
            
            Button(action: {
                viewModel.deleteSession(cardId: cardId, sessionId: session.id)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(0)
            .padding(4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            activateSession()
        }
    }
    
    private var sessionColor: Color {
        if session.splitId != nil {
            return .green
        }
        return .gray
    }
    
    private func activateSession() {
        // TODO: Terminal bridge - focus or create split
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionRowViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SessionRowView.swift
git commit -m "feat(kanban): add SessionRowView with status indicator and worktree badge"
```

---

## Task 9: SidePanelView (Main Container)

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/SidePanelView.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class SidePanelViewTests: XCTestCase {
    func testSidePanelViewHasProjectTabs() {
        let view = SidePanelView()
        let text = view.body.toString()
        XCTAssertTrue(text.contains("Default") || text.contains("Project"))
    }
    
    func testSidePanelViewHasAllFourColumns() {
        let view = SidePanelView()
        let text = view.body.toString()
        XCTAssertTrue(text.contains("Todo"))
        XCTAssertTrue(text.contains("In Progress"))
        XCTAssertTrue(text.contains("Review"))
        XCTAssertTrue(text.contains("Done"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter SidePanelViewTests`
Expected: FAIL - SidePanelView doesn't exist

- [ ] **Step 3: Write SidePanelView.swift**

```swift
import SwiftUI

struct SidePanelView: View {
    @StateObject var viewModel = SidePanelViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            ProjectTabBar(viewModel: viewModel)
            
            Divider()
            
            kanbanBoard
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var kanbanBoard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(CardStatus.allCases, id: \.self) { status in
                    KanbanColumn(
                        status: status,
                        cards: viewModel.currentProject?.cards.filter { $0.status == status } ?? [],
                        viewModel: viewModel
                    )
                }
            }
            .padding(16)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SidePanelViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SidePanelView.swift
git commit -m "feat(kanban): add SidePanelView main container with kanban board"
```

---

## Task 10: ProjectTabBar

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/ProjectTabBar.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class ProjectTabBarTests: XCTestCase {
    func testProjectTabBarShowsProjectName() {
        let vm = SidePanelViewModel()
        vm.addProject(name: "My Project")
        let bar = ProjectTabBar(viewModel: vm)
        let text = bar.body.toString()
        XCTAssertTrue(text.contains("My Project"))
    }
    
    func testProjectTabBarHasAddButton() {
        let vm = SidePanelViewModel()
        let bar = ProjectTabBar(viewModel: vm)
        let text = bar.body.toString()
        XCTAssertTrue(text.contains("+"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter ProjectTabBarTests`
Expected: FAIL - ProjectTabBar doesn't exist

- [ ] **Step 3: Write ProjectTabBar.swift**

```swift
import SwiftUI

struct ProjectTabBar: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @State private var showingAddProject = false
    @State private var newProjectName = ""
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(viewModel.projects.enumerated()), id: \.element.id) { index, project in
                    ProjectTab(
                        name: project.name,
                        isSelected: index == viewModel.currentProjectIndex,
                        onSelect: { viewModel.selectProject(at: index) },
                        onDelete: viewModel.projects.count > 1 ? { viewModel.deleteProject(at: index) } : nil
                    )
                }
                
                Button(action: { showingAddProject = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Add Project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("New Project", isPresented: $showingAddProject) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {
                newProjectName = ""
            }
            Button("Create") {
                if !newProjectName.isEmpty {
                    viewModel.addProject(name: newProjectName)
                    newProjectName = ""
                }
            }
        }
    }
}

struct ProjectTab: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
            
            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectTabBarTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/ProjectTabBar.swift
git commit -m "feat(kanban): add ProjectTabBar with project tabs and add/delete"
```

---

## Task 11: AddSessionSheet

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/AddSessionSheet.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class AddSessionSheetTests: XCTestCase {
    func testAddSessionSheetHasNameField() {
        let sheet = AddSessionSheet(cardId: "c1", viewModel: SidePanelViewModel())
        let text = sheet.body.toString()
        XCTAssertTrue(text.contains("Session") || text.contains("session"))
    }
    
    func testAddSessionSheetHasWorktreeToggle() {
        let sheet = AddSessionSheet(cardId: "c1", viewModel: SidePanelViewModel())
        let text = sheet.body.toString()
        XCTAssertTrue(text.contains("Worktree") || text.contains("worktree"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter AddSessionSheetTests`
Expected: FAIL - AddSessionSheet doesn't exist

- [ ] **Step 3: Write AddSessionSheet.swift**

```swift
import SwiftUI

struct AddSessionSheet: View {
    let cardId: String
    @ObservedObject var viewModel: SidePanelViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var sessionName = ""
    @State private var cwd = ""
    @State private var command = ""
    @State private var isWorktree = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Session")
                .font(.headline)
            
            Form {
                TextField("Session Name", text: $sessionName)
                TextField("Working Directory", text: $cwd)
                TextField("Command", text: $command)
            }
            
            Toggle("Create Worktree", isOn: $isWorktree)
                .toggleStyle(.switch)
            
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Add") {
                    addSession()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sessionName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
    
    private func addSession() {
        let session = Session(
            name: sessionName,
            cwd: cwd.isEmpty ? "~" : cwd,
            command: command.isEmpty ? "" : command,
            isWorktree: isWorktree,
            worktreeName: isWorktree ? sessionName.lowercased().replacingOccurrences(of: " ", with: "-") : nil
        )
        viewModel.addSession(to: cardId, session: session)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AddSessionSheetTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/AddSessionSheet.swift
git commit -m "feat(kanban): add AddSessionSheet for adding sessions to cards"
```

---

## Task 12: CardEditSheet

**Files:**
- Create: `macos/Sources/Ghostty/SidePanel/CardEditSheet.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Ghostty

final class CardEditSheetTests: XCTestCase {
    func testCardEditSheetShowsCardTitle() {
        let card = Card(title: "Edit Me", status: .todo, priority: .p1)
        let sheet = CardEditSheet(card: card, viewModel: SidePanelViewModel())
        let text = sheet.body.toString()
        XCTAssertTrue(text.contains("Edit Me"))
    }
    
    func testCardEditSheetHasPriorityPicker() {
        let card = Card(title: "Test", status: .todo, priority: .p2)
        let sheet = CardEditSheet(card: card, viewModel: SidePanelViewModel())
        let text = sheet.body.toString()
        XCTAssertTrue(text.contains("P0") || text.contains("P1") || text.contains("P2") || text.contains("P3"))
    }
}
```

- [ ] **Step 2: Run test - verify it fails**

Run: `swift test --filter CardEditSheetTests`
Expected: FAIL - CardEditSheet doesn't exist

- [ ] **Step 3: Write CardEditSheet.swift**

```swift
import SwiftUI

struct CardEditSheet: View {
    @Binding var card: Card
    @ObservedObject var viewModel: SidePanelViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var description: String
    @State private var priority: Priority
    @State private var status: CardStatus
    @State private var showingAddSession = false
    
    init(card: Binding<Card>, viewModel: SidePanelViewModel) {
        self._card = card
        self.viewModel = viewModel
        self._title = State(initialValue: card.wrappedValue.title)
        self._description = State(initialValue: card.wrappedValue.description)
        self._priority = State(initialValue: card.wrappedValue.priority)
        self._status = State(initialValue: card.wrappedValue.status)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Card")
                .font(.headline)
            
            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description)
                
                Picker("Priority", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                }
                
                Picker("Status", selection: $status) {
                    ForEach(CardStatus.allCases, id: \.self) { s in
                        Text(s.title).tag(s)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sessions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { showingAddSession = true }) {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 12))
                    }
                }
                
                if card.sessions.isEmpty {
                    Text("No sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(card.sessions) { session in
                        SessionRowView(session: session, cardId: card.id, viewModel: viewModel)
                    }
                }
            }
            
            HStack {
                Spacer()
                Button("Delete", role: .destructive) {
                    viewModel.deleteCard(id: card.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    saveCard()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
        .sheet(isPresented: $showingAddSession) {
            AddSessionSheet(cardId: card.id, viewModel: viewModel)
        }
    }
    
    private func saveCard() {
        card.title = title
        card.description = description
        card.priority = priority
        card.status = status
        viewModel.updateCard(card)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardEditSheetTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/CardEditSheet.swift
git commit -m "feat(kanban): add CardEditSheet for editing card details and sessions"
```

---

## Task 13: Window Integration (NavigationSplitView)

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalViewContainer.swift` (or similar)

- [ ] **Step 1: Find TerminalView instantiation**

Search for `TerminalView()` in macos/Sources and identify where the main window content is set.

- [ ] **Step 2: Replace with NavigationSplitView**

Replace:
```swift
TerminalView()
```

With:
```swift
NavigationSplitView {
    SidePanelView()
} detail: {
    TerminalView()
}
```

- [ ] **Step 3: Add import if needed**

```swift
import Ghostty
```

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Terminal/
git commit -m "feat(kanban): integrate SidePanelView into main window via NavigationSplitView"
```

---

## Task 14: Cmd+Shift+S Keyboard Shortcut

**Files:**
- Modify: Event handler or AppDelegate

- [ ] **Step 1: Find keyboard shortcut handling**

Search for existing keyboard shortcuts like `Cmd+` patterns.

- [ ] **Step 2: Add toggle handler**

```swift
.onKeyPress(.s, modifiers: [.command, .shift]) {
    sidePanelViewModel.isVisible.toggle()
    return .handled
}
```

Or if using a different pattern, integrate with Ghostty's event system.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(kanban): add Cmd+Shift+S to toggle sidebar visibility"
```

---

## Task 15: Platform Abstraction (apprt/sidepanel.zig)

**Files:**
- Create: `src/apprt/sidepanel.zig`

- [ ] **Step 1: Write interface definition**

```zig
const std = @import("std");

pub const SidePanel = struct {
    pub const Interface = struct {
        create_split: *const fn () []const u8,
        focus_split: *const fn ([]const u8) void,
        split_exists: *const fn ([]const u8) bool,
        run_command: *const fn (split: []const u8, cwd: []const u8, cmd: []const u8) void,
    };
    
    pub fn create(comptime T: type) Interface { ... }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/apprt/sidepanel.zig
git commit -m "feat(kanban): add apprt sidepanel interface for platform abstraction"
```

---

## Task 16: Terminal Bridge (Split Management)

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/SidePanelViewModel.swift`

- [ ] **Step 1: Implement activate method**

```swift
func activate(_ session: Session) {
    if let splitId = session.splitId, splitExists(splitId) {
        focusSplit(splitId)
        return
    }
    
    let newSplitId = createSplit()
    if session.isWorktree {
        createWorktree(name: session.worktreeName ?? "wt-\(session.id)")
    }
    runCommand(split: newSplitId, cwd: session.cwd, command: session.command)
}
```

- [ ] **Step 2: Implement private helpers**

```swift
private func createSplit() -> String { ... }
private func focusSplit(_ id: String) { ... }
private func splitExists(_ id: String) -> Bool { ... }
private func runCommand(split: String, cwd: String, command: String) { ... }
private func createWorktree(name: String) { ... }
```

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(kanban): add terminal bridge for split/session management"
```

---

## Verification

1. Build succeeds: `zig build -Dtarget=native-macos`
2. macOS app runs without crash
3. Sidebar appears when enabled
4. Cards can be created, edited, dragged between columns
5. Sessions can be added to cards
6. `Cmd+Shift+S` toggles sidebar
7. JSON persistence works across restarts

---

## Spec Coverage Check

| Requirement | Task(s) |
|------------|---------|
| Multi-project support | 10 (ProjectTabBar), 5 (ViewModel) |
| Kanban board (4 columns) | 6 (KanbanColumn), 9 (SidePanelView) |
| Drag-and-drop cards | 6 (KanbanColumn dropDestination) |
| Priority levels | 4 (Models), 7 (CardView) |
| Session management | 8 (SessionRowView), 11 (AddSessionSheet) |
| Split/session activation | 16 (Terminal Bridge) |
| Cmd+Shift+S toggle | 14 (Keyboard shortcut) |
| JSON persistence | 2 (store.zig), 5 (ViewModel load/save) |
| Config options | 3 (Config) |

All requirements covered.
