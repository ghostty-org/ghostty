import CoreTransferable
import UniformTypeIdentifiers

extension Ghostty.SurfaceView: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .ghosttySurfaceId) { surface in
            withUnsafeBytes(of: surface.id.uuid) { Data($0) }
        } importing: { data in
            throw TransferError.importNotSupported
        }
    }

    enum TransferError: Error {
        case importNotSupported
    }
}

extension UTType {
    static let ghosttySurfaceId = UTType(exportedAs: "com.mitchellh.ghosttySurfaceId")
}
