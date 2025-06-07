import Foundation

extension Duration {
    var timeInterval: TimeInterval {
        return TimeInterval(self.components.seconds) +
               TimeInterval(self.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
