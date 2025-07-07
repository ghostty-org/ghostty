import AppKit
import AppIntents
import SwiftUI

struct TerminalEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Working Directory")
    var workingDirectory: String?

    @Property(title: "Kind")
    var kind: Kind

    var screenshot: Image?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    @MainActor
    var displayRepresentation: DisplayRepresentation {
        var rep = DisplayRepresentation(title: "\(title)")
        if let screenshot,
           let nsImage = ImageRenderer(content: screenshot).nsImage,
           let data = nsImage.tiffRepresentation {
            rep.image = .init(data: data)
        }

        return rep
    }

    /// Returns the view associated with this entity. This may no longer exist.
    @MainActor
    var surfaceView: Ghostty.SurfaceView? {
        Self.defaultQuery.all.first { $0.uuid == self.id }
    }

    @MainActor
    var surfaceModel: Ghostty.Surface? {
        surfaceView?.surfaceModel
    }

    static var defaultQuery = TerminalQuery()

    init(_ view: Ghostty.SurfaceView) {
        self.id = view.uuid
        self.title = view.title
        self.workingDirectory = view.pwd
        self.screenshot = view.screenshot()
        
        // Determine the kind based on the window controller type
        if view.window?.windowController is QuickTerminalController {
            self.kind = .quick
        } else {
            self.kind = .normal
        }
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
            identifiers.contains($0.uuid)
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
