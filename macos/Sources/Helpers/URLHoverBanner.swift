import SwiftUI

struct URLHoverBanner: View {
    // True if we're hovering over the left URL view, so we can show it on the right.
    @State private var isHoveringURLLeft: Bool = false
    let padding: CGFloat = 5
    let cornerRadius: CGFloat = 9
    let url: String
    var body: some View {
        ZStack {
            HStack {
                Spacer()
                VStack(alignment: .leading) {
                    Spacer()

                    Text(verbatim: url)
                        .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
                        .background(
                            UnevenRoundedRectangle(cornerRadii: .init(topLeading: cornerRadius))
                                .fill(.background)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(isHoveringURLLeft ? 1 : 0)
                }
            }

            HStack {
                VStack(alignment: .leading) {
                    Spacer()

                    Text(verbatim: url)
                        .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
                        .background(
                            UnevenRoundedRectangle(cornerRadii: .init(topTrailing: cornerRadius))
                                .fill(.background)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(isHoveringURLLeft ? 0 : 1)
                        .onHover(perform: { hovering in
                            isHoveringURLLeft = hovering
                        })
                }
                Spacer()
            }
        }
    }
}
