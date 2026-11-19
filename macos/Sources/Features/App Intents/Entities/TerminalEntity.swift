import AppKit
import AppIntents
import Combine
import CoreSpotlight
import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "AppIntents.TerminalEntity"
)

struct TerminalEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Working Directory")
    var workingDirectory: String?

    @Property(title: "PID")
    var pid: Int?

    @Property(title: "TTY")
    var tty: String?

    @Property(title: "Kind")
    var kind: Kind

    var screenshot: NSImage?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    @MainActor
    var displayRepresentation: DisplayRepresentation {
        var rep = DisplayRepresentation(title: "\(title)")
        if let screenshot,
           let data = screenshot.tiffRepresentation {
            rep.image = .init(data: data)
        }

        return rep
    }

    /// Returns the view associated with this entity. This may no longer exist.
    @MainActor
    var surfaceView: Ghostty.SurfaceView? {
        Self.defaultQuery.all.first { $0.id == self.id }
    }

    @MainActor
    var surfaceModel: Ghostty.Surface? {
        surfaceView?.surfaceModel
    }

    static var defaultQuery = TerminalQuery()

    @MainActor
    init(_ view: Ghostty.SurfaceView) {
        self.id = view.id
        self.title = Self.effectiveTitle(view)
        self.workingDirectory = view.pwd
        self.pid = view.surfaceModel?.foregroundPID
        self.tty = view.surfaceModel?.ttyName
        if let nsImage = ImageRenderer(content: view.screenshot()).nsImage {
            self.screenshot = nsImage
        }

        // Determine the kind based on the window controller type
        if view.window?.windowController is QuickTerminalController {
            self.kind = .quick
        } else {
            self.kind = .normal
        }
    }

    /// Wait for the surface to be updated then create an entity
    ///
    /// The PTY/Config sets the title and pwd asynchronously shortly after the
    /// surface is created, so concurrently wait for the second published
    /// value of each (the first is the current value) before returning.
    ///
    /// If a value never arrives, the timeout completes the publisher and
    /// we fall back to the current value.
    ///
    /// Waiting for the title and pwd also gives the SurfaceView time to lay
    /// out, so the screenshot we capture afterwards reflects the rendered view.
    @MainActor
    init(view: Ghostty.SurfaceView) async {
        self.id = view.id
        self.tty = view.surfaceModel?.ttyName

        let waitTimeout = DispatchQueue.SchedulerTimeType.Stride.seconds(1)
        let titleValues = view.$title.dropFirst()
            .setFailureType(to: Error.self)
            .timeout(waitTimeout, scheduler: DispatchQueue.main, customError: { EntityTimeoutError() })
            .handleEvents(receiveCompletion: { completion in
                if case .failure = completion {
                    logger.error("failed to get terminal's title: timeout")
                }
            })
            .replaceError(with: view.title)
            .values
        let pwdValues = view.$pwd.dropFirst()
            .setFailureType(to: Error.self)
            .timeout(waitTimeout, scheduler: DispatchQueue.main, customError: { EntityTimeoutError() })
            .handleEvents(receiveCompletion: { completion in
                if case .failure = completion {
                    logger.error("failed to get terminal's pwd: timeout")
                }
            })
            .replaceError(with: view.pwd)
            .values
        async let title = titleValues.first(where: { _ in true })
        async let pwd = pwdValues.first(where: { _ in true })

        self.title = Self.effectiveTitle(view, title: await title ?? "")
        self.workingDirectory = await pwd ?? ""

        // Wait for the title and pwd then get latest pid and screenshots.
        // This should gave SurfaceView enough time to layout in the window and we can get the most recent process's PID
        // Determine the kind based on the window controller type
        if view.window?.windowController is QuickTerminalController {
            self.kind = .quick
        } else {
            self.kind = .normal
        }

        self.pid = view.surfaceModel?.foregroundPID
        if let nsImage = ImageRenderer(content: view.screenshot()).nsImage {
            self.screenshot = nsImage
        }
    }

    @MainActor
    private static func effectiveTitle(
        _ view: Ghostty.SurfaceView,
        title: String? = nil
    ) -> String {
        if let title = view.titleOverride {
            return title
        }

        if let controller = view.window?.windowController as? BaseTerminalController,
           let title = controller.titleOverride {
            return title
        }

        return title ?? view.title
    }
}

extension TerminalEntity {
    enum Kind: String, AppEnum {
        case normal
        case quick

        static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Kind")

        static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .normal: .init(title: "Normal"),
            .quick: .init(title: "Quick")
        ]
    }
}

struct TerminalQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    func entities(for identifiers: [TerminalEntity.ID]) async throws -> [TerminalEntity] {
        return all.filter {
            identifiers.contains($0.id)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TerminalEntity] {
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(string)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func allEntities() async throws -> [TerminalEntity] {
        return all.map { TerminalEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TerminalEntity] {
        return try await allEntities()
    }

    @MainActor
    var all: [Ghostty.SurfaceView] {
        // Find all of our terminal windows. This will include the quick terminal
        // but only if it was previously opened.
        let controllers = NSApp.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        // Get all our surfaces
        return controllers.flatMap {
            $0.surfaceTree.root?.leaves() ?? []
        }
    }
}

private struct EntityTimeoutError: Error {}

@available(macOS 15.0, *)
extension TerminalEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.contentDescription = [
            workingDirectory,
            tty,
            pid.map(String.init)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        attributes.keywords = [title, workingDirectory, tty].compactMap { $0 }
        return attributes
    }
}

@available(macOS 15.0, *)
extension TerminalEntity {
    @MainActor
    static func updateSpotlightIndex() {
        indexUpdateTask?.cancel()
        indexUpdateTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()

                let entities = try await Self.defaultQuery.allEntities()
                let index = CSSearchableIndex(name: "com.mitchellh.ghostty.terminals")
                try await index.deleteAppEntities(ofType: TerminalEntity.self)
                try await index.indexAppEntities(entities)
            } catch is CancellationError {
                return
            } catch {
                logger.error("failed to update terminal Spotlight index: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    private static var indexUpdateTask: Task<Void, Never>?
}
