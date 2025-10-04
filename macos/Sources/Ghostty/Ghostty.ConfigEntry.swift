import Combine
import GhosttyKit
import SwiftUI

/// An object that has reference to a `ghostty_config_t`
protocol GhosttyConfigObject: AnyObject {
    var config: ghostty_config_t? { get }
}

protocol GhosttyConfigValueConvertible: CustomStringConvertible {
    associatedtype GhosttyValue
    init(ghosttyValue: GhosttyValue?)
}

extension Ghostty {
    // This could be turned into a macro
    @propertyWrapper
    struct ConfigEntry<Value: GhosttyConfigValueConvertible> {
        static subscript<T: GhosttyConfigObject>(
            _enclosingInstance instance: T,
            wrapped _: ReferenceWritableKeyPath<T, Value>,
            storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
        ) -> Value {
            get {
                let info = instance[keyPath: storageKeyPath].info
                guard info.needsUpdate, let cfg = instance.config else {
                    return instance[keyPath: storageKeyPath].storage.value
                }
                // read from config once
                var v: Value.GhosttyValue?
                let key = info.key
                let result = withUnsafeMutablePointer(to: &v) { p in
                    ghostty_config_get(cfg, p, key, UInt(key.count))
                }
                guard result, let v else {
                    return instance[keyPath: storageKeyPath].storage.value
                }
                info.needsUpdate = false
                let value = Value(ghosttyValue: v)
                if let publisher = (instance as? any ObservableObject)?.objectWillChange as? ObservableObjectPublisher {
                    DispatchQueue.main.async {
                        publisher.send()
                    }
                }
                instance[keyPath: storageKeyPath].storage.value = value
                return value
            }

            set {
                if let publisher = (instance as? any ObservableObject)?.objectWillChange as? ObservableObjectPublisher {
                    DispatchQueue.main.async {
                        publisher.send()
                    }
                }
                instance[keyPath: storageKeyPath].storage.value = newValue
                let key = instance[keyPath: storageKeyPath].info.key
                let stringValue = String(describing: newValue)
                guard let cfg = instance.config else {
                    return
                }
                ghostty_config_set(cfg, key, UInt(key.count), stringValue, UInt(stringValue.count))
            }
        }

        class Info: Identifiable {
            var id: String { key }
            fileprivate var needsUpdate = true
            let key: String
            let tip: String?

            init(key: String, tip: String?) {
                self.key = key
                self.tip = tip
            }
        }

        @available(*, unavailable,
                   message: "@ConfigEntry can only be applied to GhosttyConfig")
        var wrappedValue: Value {
            get { fatalError() }
            set { fatalError() }
        }

        private var storage = CurrentValueSubject<Value, Never>(Value(ghosttyValue: nil))
        private var info: Info

        var projectedValue: AnyPublisher<Value, Never> {
            storage.eraseToAnyPublisher()
        }

        init(_ key: String, tip: String? = nil) {
            info = .init(key: key, tip: tip)
        }
    }
}

// MARK: - Common Types

extension Optional: @retroactive CustomStringConvertible where Wrapped: CustomStringConvertible {
    public var description: String {
        switch self {
        case .none:
            return ""
        case .some(let wrapped):
            return wrapped.description
        }
    }
}

extension Optional: GhosttyConfigValueConvertible where Wrapped: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Wrapped.GhosttyValue
    init(ghosttyValue: GhosttyValue?) {
        guard let pointer = ghosttyValue else {
            self = .none
            return
        }
        self = .some(Wrapped(ghosttyValue: pointer))
    }
}

extension String: GhosttyConfigValueConvertible {
    typealias GhosttyValue = UnsafePointer<UInt8>
    init(ghosttyValue: GhosttyValue?) {
        guard let p = ghosttyValue else {
            self = ""
            return
        }
        // If you want extra safety, you can use `String(validatingUTF8:) ?? ""`
        self = String(cString: p)
    }
}

extension Bool: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self

    init(ghosttyValue: Bool?) {
        self = ghosttyValue ?? false
    }
}

extension UInt: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self
    init(ghosttyValue: UInt?) {
        self = ghosttyValue ?? .zero
    }
}

extension Double: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self

    init(ghosttyValue: Double?) {
        self = ghosttyValue ?? 0
    }
}

extension Color: GhosttyConfigValueConvertible {
    typealias GhosttyValue = ghostty_config_color_s
    init(ghosttyValue: GhosttyValue?) {
        guard let color = ghosttyValue else {
            self = .clear
            return
        }
        self = .init(
            red: Double(color.r) / 255,
            green: Double(color.g) / 255,
            blue: Double(color.b) / 255
        )
    }
}
