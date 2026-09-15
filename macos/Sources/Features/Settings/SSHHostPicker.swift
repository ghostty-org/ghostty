import SwiftUI

/// A plain SwiftUI label keeps spacing intact instead of letting AppKit's Menu
/// bridge reinterpret the label's individual text and image elements.
struct SSHHostPicker<Label: View>: View {
    struct Item: Identifiable {
        let id: String
        let title: String
    }
    let items: [Item]
    @Binding var selection: String
    @ViewBuilder var label: () -> Label
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            Button {
                                selection = item.id
                                presented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark").opacity(selection == item.id ? 1 : 0)
                                    Text(item.title).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 32)
                                .contentShape(Rectangle())
                                .background(selection == item.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain).help(item.title)
                        }
                    }.padding(6)
                }
                .frame(width: 420, height: CGFloat(min(items.count * 34 + 12, 352)))
            }
    }
}
