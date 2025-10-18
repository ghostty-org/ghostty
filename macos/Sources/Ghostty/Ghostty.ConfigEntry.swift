import Combine
import GhosttyKit
import SwiftUI

/// An object that has reference to a `ghostty_config_t`
protocol GhosttyConfigObject: AnyObject {
    var config: ghostty_config_t? { get }
}

extension GhosttyConfigObject {
    @MainActor
    func reload(for preferredApp: ghostty_app_t? = nil) {
        guard let cfg = config else {
            return
        }

        // we only finalise config temporarily = hard reload
        let newCfg = ghostty_config_clone(cfg)
        if let app = preferredApp ?? (NSApp.delegate as? AppDelegate)?.ghostty.app {
            ghostty_config_finalize(newCfg)
            ghostty_app_update_config(app, newCfg)
        }
    }

    func setValue(_ key: String, value: String) -> Bool {
        guard let config = config else { return false }
        let result = ghostty_config_set(config, key, UInt(key.count), value, UInt(value.count))
        return result
    }

    @MainActor
    func export() -> String {
        guard
            let config = config,
            let exported = ghostty_config_export_string(config)
        else { return "" }
        return String(cString: exported)
    }
}

protocol GhosttyConfigValueConvertible {
    associatedtype GhosttyValue
    init(ghosttyValue: GhosttyValue?)
    var representedValue: [String] { get }
}

protocol GhosttyConfigValueConvertibleBridge {
    associatedtype Value: GhosttyConfigValueConvertible
    associatedtype UnderlyingValue: GhosttyConfigValueConvertible

    static func convert(underlying: UnderlyingValue) -> Value
    static func convert(value: Value) -> UnderlyingValue
}

struct TollFreeBridge<Value: GhosttyConfigValueConvertible>: GhosttyConfigValueConvertibleBridge {
    typealias UnderlyingValue = Value

    static func convert(value: Value) -> Value {
        value
    }

    static func convert(underlying: Value) -> Value {
        underlying
    }
}

struct BinaryFloatingPointBridge<Value: BinaryFloatingPoint & GhosttyConfigValueConvertible, UnderlyingValue: BinaryFloatingPoint & GhosttyConfigValueConvertible>: GhosttyConfigValueConvertibleBridge {
    static func convert(value: Value) -> UnderlyingValue {
        UnderlyingValue(value)
    }

    static func convert(underlying: UnderlyingValue) -> Value {
        Value(underlying)
    }
}

extension Ghostty {
    // This could be turned into a macro
    @propertyWrapper
    struct ConfigEntry<Value: GhosttyConfigValueConvertible, UnderlyingValue: GhosttyConfigValueConvertible, Bridge: GhosttyConfigValueConvertibleBridge>: DynamicProperty where Bridge.Value == Value, Bridge.UnderlyingValue == UnderlyingValue {
        static func getValue(from cfg: ghostty_config_t, key: String) -> Value? {
            var v: Bridge.UnderlyingValue.GhosttyValue?
            // finalise a temporary config to get default values
            let tempCfg = ghostty_config_clone(cfg)
            ghostty_config_finalize(tempCfg)

            let result = withUnsafeMutablePointer(to: &v) { p in
                ghostty_config_get(tempCfg, p, key, UInt(key.count))
            }
            // we need to 'check' `v` here to extend the life time.
            // `guard let v( = v)` unwraps it and binds it to a new constant named v,
            // so that we can safely use it in the bridge
            guard result, let v else {
                return nil
            }
            let underlying = Bridge.convert(underlying: Bridge.UnderlyingValue(ghosttyValue: v))
            return underlying
        }

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
                guard let value = getValue(from: cfg, key: info.key) else {
                    return instance[keyPath: storageKeyPath].storage.value
                }
                instance[keyPath: storageKeyPath].info.needsUpdate = false
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
                guard let cfg = instance.config else {
                    return
                }
                let info = instance[keyPath: storageKeyPath].info
                let key = info.key
                ghostty_config_set(cfg, key, UInt(key.count), "", 0) // reset
                // convert back to underlying value using bridge
                // before writing to ghostty_config_t
                let underlyingValue = Bridge.convert(value: newValue)
                for value in underlyingValue.representedValue {
                    ghostty_config_set(cfg, key, UInt(key.count), value, UInt(value.count))
                }
                if info.reloadOnSet {
                    DispatchQueue.main.async {
                        instance.reload()
                    }
                }
            }
        }

        struct Info: Identifiable {
            var id: String { key }
            fileprivate var needsUpdate = true
            let key: String
            let tip: String?
            let reloadOnSet: Bool

            init(key: String, tip: String?, reloadOnSet: Bool) {
                self.key = key
                self.tip = tip
                self.reloadOnSet = reloadOnSet
            }
        }

        @available(*, unavailable,
                   message: "@ConfigEntry can only be applied to GhosttyConfig")
        var wrappedValue: Value {
            get { fatalError() }
            set { fatalError() }
        }

        private var storage = CurrentValueSubject<Value, Never>(Value(ghosttyValue: nil))
        @State private var info: Info

        var projectedValue: AnyPublisher<Value, Never> {
            storage.eraseToAnyPublisher()
        }

        init(_ key: String, tip: String? = nil, reload: Bool = true, bridge _: Bridge.Type) {
            info = .init(key: key, tip: tip, reloadOnSet: reload)
        }
    }
}

extension Ghostty.ConfigEntry where Bridge == TollFreeBridge<Value> {
    init(_ key: String, tip: String? = nil, reload: Bool = true) {
        self.init(key, tip: tip, reload: reload, bridge: Bridge.self)
    }
}

extension Ghostty.ConfigEntry where Bridge == BinaryFloatingPointBridge<Value, UnderlyingValue> {
    init(_ key: String, tip: String? = nil, reload: Bool = true, from: UnderlyingValue.Type) {
        self.init(key, tip: tip, reload: reload, bridge: Bridge.self)
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

    var representedValue: [String] {
        self?.representedValue ?? []
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

    var representedValue: [String] {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        } else {
            return [trimmed]
        }
    }
}

extension Bool: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self

    init(ghosttyValue: Bool?) {
        self = ghosttyValue ?? false
    }

    var representedValue: [String] {
        ["\(self)"]
    }
}

extension UInt: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self
    init(ghosttyValue: UInt?) {
        self = ghosttyValue ?? .zero
    }

    var representedValue: [String] {
        ["\(self)"]
    }
}

/// `f32`
extension Float: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self

    init(ghosttyValue: GhosttyValue?) {
        self = ghosttyValue ?? 0
    }

    var representedValue: [String] {
        [formatted(.number.precision(.fractionLength(3)))]
    }
}

/// `f64`
extension Double: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self

    init(ghosttyValue: GhosttyValue?) {
        self = ghosttyValue ?? 0
    }

    var representedValue: [String] {
        [formatted(.number.precision(.fractionLength(3)))]
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

    var representedValue: [String] {
        let osColor = OSColor(self)
        guard let components = osColor.cgColor.components, components.count >= 3 else {
            return []
        }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        var a = Float(1.0)

        if components.count >= 4 {
            a = Float(components[3])
        }

        return [String(format: "%02lX%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255), lroundf(a * 255))]
    }
}

// MARK: - Ghostty Bridge Types

extension Array: GhosttyConfigValueConvertible where Element == Ghostty.RepeatableItem {
    typealias GhosttyValue = ghostty_config_repeatable_item_list_s

    init(ghosttyValue: ghostty_config_repeatable_item_list_s?) {
        guard let list = ghosttyValue else {
            self = []
            return
        }
        self = .init(list)
    }

    var representedValue: [String] {
        map(\.value)
    }
}

extension Ghostty.AutoUpdateChannel: GhosttyConfigValueConvertible {
    typealias GhosttyValue = String.GhosttyValue

    init(ghosttyValue: String.GhosttyValue?) {
        let rawValue = String(ghosttyValue: ghosttyValue)
        self = Self(rawValue: rawValue) ?? .stable
    }

    var representedValue: [String] {
        [rawValue]
    }
}
