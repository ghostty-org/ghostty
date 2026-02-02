import SwiftUI

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .worktrunk

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
            .modifier(RemoveSidebarToggleModifier())
        } detail: {
            selectedSection.view
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 450)
    }
}

private struct RemoveSidebarToggleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case worktrunk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worktrunk: return "Worktrunk"
        }
    }

    var icon: String {
        switch self {
        case .worktrunk: return "arrow.triangle.branch"
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .worktrunk: WorktrunkSettingsView()
        }
    }
}
