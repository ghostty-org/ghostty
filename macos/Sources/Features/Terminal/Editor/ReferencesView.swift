import SwiftUI

/// One place a symbol is used, with the line of code it sits on.
///
/// The server answers with coordinates and nothing else, so the line is
/// read from disk here. Without it the list is a column of file names and
/// numbers — technically the answer, and useless for deciding which of the
/// forty results is the one you meant.
struct LSPReference: Identifiable {
    let location: LSPLocation
    let snippet: String

    var id: String { location.id }

    var name: String { (location.path as NSString).lastPathComponent }

    /// Lines are zero-based in the protocol and one-based to a reader.
    var line: Int { location.range.start.line + 1 }

    init(_ location: LSPLocation) {
        self.location = location
        self.snippet = Self.line(location.range.start.line, ofFileAt: location.path)
    }

    static func line(_ index: Int, ofFileAt path: String) -> String {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard index >= 0, index < lines.count else { return "" }
        return lines[index].trimmingCharacters(in: .whitespaces)
    }
}

/// The list of references, in the same shape as a workspace search.
struct ReferencesView: View {
    let references: [LSPReference]
    let onSelect: (LSPReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var palette: ThemePalette = .shared

    /// Grouped by file, because a symbol used eleven times in one file and
    /// once in another is a different thing from twelve scattered uses, and
    /// a flat list hides which one you are looking at.
    private var byFile: [(path: String, references: [LSPReference])] {
        Dictionary(grouping: references, by: \.location.path)
            .map { (path: $0.key, references: $0.value.sorted { $0.line < $1.line }) }
            .sorted { $0.path < $1.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("References")
                    .font(palette.font(size: 13).weight(.semibold))
                Text("\(references.count)")
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            List {
                ForEach(byFile, id: \.path) { group in
                    Section {
                        ForEach(group.references) { reference in
                            row(reference)
                        }
                    } header: {
                        Text((group.path as NSString).lastPathComponent)
                            .font(palette.font(size: 11).weight(.medium))
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 420)
    }

    private func row(_ reference: LSPReference) -> some View {
        Button {
            onSelect(reference)
        } label: {
            HStack(spacing: 8) {
                Text("\(reference.line)")
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Text(reference.snippet)
                    .font(palette.font(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
