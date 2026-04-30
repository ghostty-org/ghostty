import SwiftUI

extension View {
    func innerShadow<S: Shape, ST: ShapeStyle>(
        using shape: S = Rectangle(),
        stroke: ST = Color.black,
        width: CGFloat = 6,
        blur: CGFloat = 6
    ) -> some View {
        return self
            .overlay(
                shape
                    .stroke(stroke, lineWidth: width)
                    .blur(radius: blur)
                    .mask(shape)
            )
    }
}

extension View {
    func pointerStyleFromCursor(_ cursor: NSCursor) -> some View {
        if #available(macOS 15.0, *) {
            return self.pointerStyle(.image(
                Image(nsImage: cursor.image),
                hotSpot: .init(x: cursor.hotSpot.x, y: cursor.hotSpot.y)
            ))
        } else {
            return self
        }
    }
}
