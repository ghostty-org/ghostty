import Foundation

/// What the Git panel draws below its header.
///
/// A small enum rather than a chain of `if let`s in the view, because the
/// interesting case is easy to get subtly wrong: "no status" means *two*
/// different things. Before the first `git status` comes back it means
/// "still reading", and a spinner is right. After it comes back empty — a
/// repository git refused to read — it means "there is nothing to show",
/// and the same spinner would sit there turning forever.
enum GitPanelContent: Equatable {
    /// The first status hasn't come back yet.
    case loading

    /// It came back with nothing: git couldn't read this repository.
    case unreadable

    /// A working tree with no changes.
    case clean

    /// Changes to list.
    case changes

    /// - Parameter hasLoaded: whether a first load has *finished* for this
    ///   repository, regardless of whether it produced a status. Passing
    ///   `status != nil` here instead is the bug this type exists to
    ///   prevent.
    static func resolve(status: GitStatus?, hasLoaded: Bool) -> GitPanelContent {
        guard let status else {
            return hasLoaded ? .unreadable : .loading
        }
        return status.isClean ? .clean : .changes
    }
}
