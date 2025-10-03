import GhosttyKit
import Combine
import SwiftUI

protocol GhosttyConfig: AnyObject {
    var config: ghostty_config_t? { get }
}

protocol GhosttyConfigValueConvertible: CustomStringConvertible {
    associatedtype Pointee
    init(ghosttyPointer: Pointee?)
}

extension Ghostty {
    // This could be turned into a macro
    @propertyWrapper
    struct ConfigEntry<Value: GhosttyConfigValueConvertible> {
        static subscript<T: GhosttyConfig>(
            _enclosingInstance instance: T,
            wrapped _: ReferenceWritableKeyPath<T, Value>,
            storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
        ) -> Value {
            get {
                let info = instance[keyPath: storageKeyPath].info
                guard info.needsUpdate, let cfg = instance.config else {
                    return instance[keyPath: storageKeyPath].storage
                }
                // read from config once
                var v: Value.Pointee?
                let key = info.key
                guard ghostty_config_get(cfg, &v, key, UInt(key.count)), let v else {
                    return instance[keyPath: storageKeyPath].storage
                }
                info.needsUpdate = false
                let value = Value(ghosttyPointer: v)
                if let publisher = (instance as? any ObservableObject)?.objectWillChange as? ObservableObjectPublisher {
                    DispatchQueue.main.async {
                        publisher.send()
                    }
                }
                instance[keyPath: storageKeyPath].storage = value
                return value
            }

            set {
                if let publisher = (instance as? any ObservableObject)?.objectWillChange as? ObservableObjectPublisher {
                    DispatchQueue.main.async {
                        publisher.send()
                    }
                }
                instance[keyPath: storageKeyPath].storage = newValue
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

        private var storage: Value!
        private var info: Info

        init(_ key: String, tip: String? = nil) {
            info = .init(key: key, tip: tip)
        }
    }
}

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
    typealias Pointee = Wrapped.Pointee
    init(ghosttyPointer: Pointee?) {
        guard let pointer = ghosttyPointer else {
            self = .none
            return
        }
        self = .some(Wrapped(ghosttyPointer: pointer))
    }
}

extension String: GhosttyConfigValueConvertible {
    typealias Pointee = UnsafePointer<UInt8>
    init(ghosttyPointer: Pointee?) {
        guard let p = ghosttyPointer else {
            self = ""
            return
        }
        // If you want extra safety, you can use `String(validatingUTF8:) ?? ""`
        self = String(cString: p)
    }
}
