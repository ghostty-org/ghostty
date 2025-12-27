#if canImport(AppKit)
import AppKit
#endif
import CoreTransferable
import UniformTypeIdentifiers

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
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }
            for surface in controller.surfaceTree {
                if surface.id == uuid {
                    return surface as? Self
                }
            }
        }
        #endif
        
        return nil
    }
}

extension UTType {
    static let ghosttySurfaceId = UTType(exportedAs: "com.mitchellh.ghosttySurfaceId")
}
