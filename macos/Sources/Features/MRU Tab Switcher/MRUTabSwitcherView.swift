import SwiftUI
import GhosttyKit

struct MRUTabEntry: Identifiable {
  let id: UUID
  let title: String
  let subtitle: String?
  let tabColor: Color?
  let focusInstant: ContinuousClock.Instant?
  let window: NSWindow

  static func sortedByMRU(_ entries: [MRUTabEntry]) -> [MRUTabEntry] {
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

  @State private var query = ""
  @State private var selectedIndex: Int = 0
  @State private var hoveredId: UUID?
  @FocusState private var isTextFieldFocused: Bool

  private var filteredTabs: [MRUTabEntry] {
    if query.isEmpty {
      return MRUTabEntry.sortedByMRU(tabs)
    }
    return MRUTabEntry.sortedByMRU(
      tabs.filter {
        $0.title.localizedCaseInsensitiveContains(query) ||
        ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
      }
    )
  }

  var body: some View {
    let scheme: ColorScheme = OSColor(backgroundColor).isLightColor ? .light : .dark

    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search tabs..", text: $query)
          .textFieldStyle(.plain)
          .focused($isTextFieldFocused)
          .onSubmit {
            selectCurrentTab()
          }
      }
      .padding()
      .font(.system(size: 16))

      Divider()

      if filteredTabs.isEmpty {
        Text("No matching tabs")
          .foregroundStyle(.secondary)
          .padding()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Array(filteredTabs.enumerated()), id: \.1.id) { index, tab in
                MRUTabRow(
                  tab: tab,
                  isSelected: index == selectedIndex,
                  isHovered: hoveredID == tab.id
                ) {
                  selectTab(tab)
                }
              }
            }
          }
        }
      }
    }
  }
}
