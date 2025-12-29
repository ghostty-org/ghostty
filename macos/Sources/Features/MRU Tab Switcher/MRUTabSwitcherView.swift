import SwiftUI
import GhosttyKit

struct KeyEventHandler: NSViewRepresentable {
  let onKeyDown: (NSEvent) -> Bool

  func makeNSView(context: Context) -> KeyEventView {
    let view = KeyEventView()
    view.onKeyDown = onKeyDown
    return view
  }

  func updateNSView(_ nsView: KeyEventView, context: Context) {
    nsView.onKeyDown = onKeyDown
  }

  class KeyEventView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    private weak var previousFirstResponder: NSResponder?
    private weak var hostWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()

      if let window = window {
        previousFirstResponder = window.firstResponder
        hostWindow = window
        DispatchQueue.main.async { [weak self] in
          self?.window?.makeFirstResponder(self)
        }
      } else {
        if hostWindow?.isKeyWindow == true, let previous = previousFirstResponder {
          hostWindow?.makeFirstResponder(previous)
        }
        previousFirstResponder = nil
        hostWindow = nil
      }
    }

    override func keyDown(with event: NSEvent) {
      if onKeyDown?(event) != true {
        super.keyDown(with: event)
      }
    }
  }
}

struct MRUTabEntry: Identifiable {
  let id: UUID
  let title: String
  let subtitle: String?
  let tabColor: Color?
  let focusInstant: ContinuousClock.Instant?
  let window: NSWindow

  static func sortedByMRU(_ entries: [MRUTabEntry]) -> [MRUTabEntry] {
    // A sort when opening the Most Recently Used Tab Switcher is reasonable since the time complexity of the sort
    // isn't a performance problem unless a user has 1000+ tabs which is unrealistic, most users have ~10 or less tabs at a time.
    // There is extra complexity in an LIFO stack approach to keep the array in order, we'd need to add listeners
    // to closing/opening new tabs and tab splits.
    entries.sorted { a, b in
      guard let aInstant = a.focusInstant else { return false }
      guard let bInstant = b.focusInstant else { return true }
      return aInstant > bInstant
    }
  }
}

struct MRUTabSwitcherView: View {
  @Binding var isPresented: Bool
  var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
  var tabs: [MRUTabEntry]
  var onSelect: (MRUTabEntry) -> Void

  @State private var selectedIndex: Int = 0
  @State private var hoveredID: UUID?
  @FocusState private var isTextFieldFocused: Bool

  private var sortedTabs: [MRUTabEntry] {
    return MRUTabEntry.sortedByMRU(tabs)
  }

  var body: some View {
    let scheme: ColorScheme = OSColor(backgroundColor).isLightColor ? .light : .dark

    VStack(alignment: .leading, spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sortedTabs.enumerated()), id: \.1.id) { index, tab in
              MRUTabRow(
                tab: tab,
                isSelected: index == selectedIndex,
                isHovered: hoveredID == tab.id
              ) {
                selectTab(tab)
              }
              .onHover { hovering in
                hoveredID = hovering ? tab.id : nil
              }
              .id(tab.id)
            }
          }
          .padding(10)
        }
        .frame(maxHeight: 300)
        .onChange(of: selectedIndex) { newValue in
          guard newValue < sortedTabs.count else { return }
          proxy.scrollTo(sortedTabs[newValue].id)
        }
      }
    }
    .frame(maxWidth: 450)
    .background(
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        Rectangle().fill(backgroundColor).blendMode(.color)
      }.compositingGroup()
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
    )
    .shadow(radius: 32, x: 0, y: 12)
    .padding()
    .environment(\.colorScheme, scheme)
    .onAppear {
      isTextFieldFocused = true
      selectedIndex = 0
    }
    .background(
      KeyEventHandler { event in
        switch event.keyCode {
          case 126:
            moveSelection(-1)
            return true
          case 125:
            moveSelection(1)
            return true
          case 53:
            isPresented = false
            return true
          case 36:
            selectCurrentTab()
            return true
          case 35:
            if event.modifierFlags.contains(.command) {
              moveSelection(1)
              return true
            }
            return false
          default:
            return false
        }
      }
    )
  }

  private func moveSelection(_ delta: Int) {
    guard !sortedTabs.isEmpty else { return }
    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      selectedIndex = sortedTabs.count - 1
    } else if newIndex >= sortedTabs.count {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  private func selectCurrentTab() {
    guard selectedIndex < sortedTabs.count else { return }
    selectTab(sortedTabs[selectedIndex])
  }

  private func selectTab(_ tab: MRUTabEntry) {
    isPresented = false
    onSelect(tab)
  }
}


fileprivate struct MRUTabRow: View {
  let tab: MRUTabEntry
  let isSelected: Bool
  let isHovered: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let color = tab.tabColor {
          Circle()
            .fill(color)
            .frame(width: 8, height: 8)
        }

        Image(systemName: "terminal")
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(tab.title)
            .lineLimit(1)

          if let subtitle = tab.subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        if let instant = tab.focusInstant {
          Text(timeAgo(from: instant))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(8)
      .contentShape(Rectangle())
      .background(
        isSelected
          ? Color.accentColor.opacity(0.2)
          : (isHovered ? Color.secondary.opacity(0.15) : Color.clear)
      )
      .cornerRadius(5)
    }
    .buttonStyle(.plain)
  }

  private func timeAgo(from instant: ContinuousClock.Instant) -> String {
    let elapsed = ContinuousClock.now - instant
    let seconds = elapsed.components.seconds

    if seconds < 60 {
      return "just now"
    } else if seconds < 3600 {
      let minutes = seconds / 60
      return "\(minutes)m ago"
    } else {
      let hours = seconds / 3600
      return "\(hours)h ago"
    }
  }
}
