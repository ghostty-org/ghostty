import Foundation

extension ObjectIdentifier {
    var hexString: String {
        String(UInt(bitPattern: self), radix: 16)
    }
}
