import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) var openURL

    /// Read the commit from the bundle.
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? { Bundle.main.infoDictionary?["GhosttyCommit"] as? String }
    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    private enum VersionConfig {
        case stable(version: String)
        case tip(commit: String?)
        case other(String)
        case none

        init(version: String?) {
            guard let version else { self = .none; return }
            if version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                self = .stable(version: version)
                return
            }
            if version.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
                self = .tip(commit: version)
                return
            }
            self = .other(version)
        }

        var url: URL? {
            switch self {
            case .stable(let version):
                let slug = version.replacingOccurrences(of: ".", with: "-")
                return URL(string: "https://ghostty.org/docs/install/release-notes/\(slug)")
            default:
                return nil
            }
        }
    }

    private var versionConfig: VersionConfig { VersionConfig(version: version) }

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    /// `Ghostty` and `Mitchell Hashimoto` as real links rather than
    /// unclickable text — parsed once so a malformed constant fails softly
    /// as plain text instead of crashing the about window.
    private var upstreamCredit: AttributedString {
        (try? AttributedString(
            markdown: Phantom.upstreamCredit,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(Phantom.upstreamCredit)
    }

    #if os(macOS)
    // This creates a background style similar to the Apple "About My Mac" Window
    private struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        let isEmphasized: Bool

        init(material: NSVisualEffectView.Material,
             blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
             isEmphasized: Bool = false) {
            self.material = material
            self.blendingMode = blendingMode
            self.isEmphasized = isEmphasized
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
            nsView.isEmphasized = isEmphasized
        }

        func makeNSView(context: Context) -> NSVisualEffectView {
            let visualEffect = NSVisualEffectView()
            visualEffect.autoresizingMask = [.width, .height]
            return visualEffect
        }
    }
    #endif

    /// The window's fixed content width. Height is deliberately not fixed
    /// here: `AboutController` measures this view's natural height at this
    /// width (`NSHostingView.fittingSize`) and sets the window's content
    /// size to exactly that, so the padding below is respected on every
    /// side instead of being guessed against a hand-picked window height —
    /// guessing is what left the bottom margin thinner than the sides.
    static let windowWidth: CGFloat = 480

    /// One consistent margin around the content, on every side — the
    /// previous extra `.padding(.top, 8)` on top of the general padding
    /// made the top inconsistent with the rest.
    private static let margin: CGFloat = 28

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            CyclingIconView()
                .frame(height: 90)

            VStack(alignment: .center, spacing: 6) {
                Text(Phantom.name)
                    .bold()
                    .font(.title)
                Text(Phantom.tagline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.caption)
                    .tint(.secondary)
                    .opacity(0.8)
            }
            .textSelection(.enabled)

            VStack(spacing: 2) {
                PropertyRow(label: "Version", text: Phantom.versionSummary)
                PropertyRow(label: "Ghostty Core", text: Phantom.upstreamCoreVersion)
                if let build {
                    PropertyRow(label: "Build", text: build)
                }
            }
            .frame(maxWidth: .infinity)

            Button("GitHub") {
                openURL(Phantom.repositoryURL)
            }

            if let copy = self.copyright {
                Text(copy)
                    .font(.caption)
                    .textSelection(.enabled)
                    .opacity(0.7)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 4) {
                Text("Powered by Ghostty 👻")
                    .font(.caption)
                    .fontWeight(.medium)

                Text(upstreamCredit)
                    .font(.caption2)
                    .opacity(0.85)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .tint(.secondary)
            }
            .padding(Self.margin * 0.6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
            )
        }
        .padding(Self.margin)
        .frame(width: Self.windowWidth)
        #if os(macOS)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
        #endif
    }

    private struct PropertyRow: View {
        private let label: String
        private let text: String
        private let url: URL?

        init(label: String, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) {
                        textView
                    }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
