#if canImport(AppKit)
import AppKit
#endif
import CoreTransferable
import UniformTypeIdentifiers

/// Conformance to `Transferable` enables drag-and-drop.
extension Ghostty.SurfaceView: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .ghosttySurfaceId) { surface in
            withUnsafeBytes(of: surface.id.uuid) { Data($0) }
        } importing: { data in
            guard data.count == 16 else {
                throw TransferError.invalidData
            }

            let uuid = data.withUnsafeBytes {
                $0.load(as: UUID.self)
            }
            
            guard let imported = await Self.find(uuid: uuid) else {
                throw TransferError.invalidData
            }
            
            return imported
        }
    }

    enum TransferError: Error {
        case invalidData
    }
    
    @MainActor
    static func find(uuid: UUID) -> Self? {
        #if canImport(AppKit)
        guard let del = NSApp.delegate as? Ghostty.Delegate else { return nil }
        return del.ghosttySurface(id: uuid) as? Self
        #elseif canImport(UIKit)
        // We should be able to use UIApplication here.
        return nil
        #else
        return nil
        #endif
    }
}

extension UTType {
    /// A format that encodes the bare UUID only for the surface. This can be used if you have
    /// a way to look up a surface by ID.
    static let ghosttySurfaceId = UTType(exportedAs: "com.mitchellh.ghosttySurfaceId")
}

#if canImport(AppKit)
extension NSPasteboard.PasteboardType {
    /// Pasteboard type for dragging surface IDs.
    static let ghosttySurfaceId = NSPasteboard.PasteboardType(UTType.ghosttySurfaceId.identifier)
}
#endif
