import SwiftUI

struct SecureInputOverlay: View {
    // Animations
    @State private var shadowAngle: Angle = .degrees(0)
    @State private var shadowWidth: CGFloat = 6

    // Popover explainer text
    @State private var isPopover = false

    var body: some View {
        VStack {
            HStack {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 25, height: 25)
                    .foregroundColor(.primary)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background)
                            .innerShadow(
                                using: RoundedRectangle(cornerRadius: 12),
                                 stroke: AngularGradient(
                                     gradient: Gradient(colors: [.cyan, .blue, .yellow, .blue, .cyan]),
                                     center: .center,
                                     angle: shadowAngle
                                 ),
                                 width: shadowWidth
                             )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray, lineWidth: 1)
                    )
                    .onTapGesture {
                        isPopover = true
                    }
                    .backport.pointerStyle(.link)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                        Text("""
                        Secure Input is active. Secure Input is a macOS security feature that
                        prevents applications from reading keyboard events. This is enabled
                        automatically whenever Ghostty detects a password prompt in the terminal,
                        or at all times if `Ghostty > Secure Keyboard Entry` is active.
                        """)
                        .padding(.all)
                    }
            }

            Spacer()
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: false)) {
                shadowAngle = .degrees(360)
            }

            withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: true)) {
                shadowWidth = 12
            }
        }
    }
}
