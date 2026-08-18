//  Reading the live framebuffer.
//
//  Used to prove, headlessly, that the IOSurface handed to CALayer really does
//  contain the guest's screen, and to give the diagnostics an oracle for "did
//  the screen respond". `simctl io screenshot` remains the better choice for a
//  user-facing screenshot: it is exact and unscaled, and it does not depend on
//  our render path being right.

import CoreImage
import Foundation
import ImageIO
import IOSurface

enum Snapshot {

    /// The IOSurface class and IOSurfaceRef are toll-free bridged, so the object
    /// CoreSimulator hands back can be reinterpreted without a copy.
    static func cgImage(from surfaceObject: AnyObject) -> CGImage? {
        let ref = unsafeBitCast(surfaceObject, to: IOSurfaceRef.self)
        let ciImage = CIImage(ioSurface: ref)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil)
        else { throw SimPaneError("could not create a PNG destination") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SimPaneError("could not encode the framebuffer as PNG")
        }
        return data as Data
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        try pngData(image).write(to: URL(fileURLWithPath: path))
    }

    /// A sparse sample of the current frame, for telling "the screen changed"
    /// from "the send was silently dropped".
    ///
    /// Two details are load-bearing and were both learned the hard way (DEVLOG,
    /// Phase 2): the stride must be small enough to catch a real change — an
    /// earlier 4093-byte stride reported false "unchanged" readings — and the top
    /// of the frame is skipped so the status-bar clock ticking over cannot read
    /// as a response.
    static func sample(of surfaceObject: AnyObject) -> [UInt8] {
        guard let image = cgImage(from: surfaceObject),
              let data = image.dataProvider?.data as Data? else { return [] }
        let start = data.count / 20
        var out: [UInt8] = []
        out.reserveCapacity(max((data.count - start) / 97, 1))
        var index = start
        while index < data.count {
            out.append(data[index])
            index += 97
        }
        return out
    }

    /// Fraction of sampled bytes that differ. Zero when the samples cannot be
    /// compared at all, which reads as "no response" — the safe direction.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var differing = 0
        for i in 0..<a.count where a[i] != b[i] { differing += 1 }
        return Double(differing) / Double(a.count)
    }
}
