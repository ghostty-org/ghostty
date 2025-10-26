import Combine
import GhosttyKit
import SwiftUI

/// An object that has reference to a `ghostty_config_t`
protocol GhosttyConfigObject: AnyObject {
    var config: ghostty_config_t? { get }
    func reload(for preferredApp: ghostty_app_t?)
}

extension GhosttyConfigObject {
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
    func representedValues(for key: String) -> [String]
}

protocol GhosttyConfigValueBridgeable {
    associatedtype UnderlyingValue: GhosttyConfigValueConvertible
    init(underlyingValue: UnderlyingValue)

    var underlyingValue: UnderlyingValue { get }
}

extension GhosttyConfigValueBridgeable where UnderlyingValue: GhosttyConfigValueConvertible, UnderlyingValue == Self {
    init(underlyingValue: UnderlyingValue) {
        self = underlyingValue
    }

    var underlyingValue: UnderlyingValue {
        self
    }
}

protocol GhosttyConfigValueConvertibleBridge {
    associatedtype Value
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

struct GeneralGhosttyValueBridge<Value: GhosttyConfigValueBridgeable, UnderlyingValue: GhosttyConfigValueConvertible>: GhosttyConfigValueConvertibleBridge where Value.UnderlyingValue == UnderlyingValue {
    static func convert(value: Value) -> UnderlyingValue {
        value.underlyingValue
    }

    static func convert(underlying: UnderlyingValue) -> Value {
        Value(underlyingValue: underlying)
    }
}

extension Ghostty {
    // This could be turned into a macro
    @propertyWrapper
    struct ConfigEntry<Value: GhosttyConfigValueBridgeable, Bridge: GhosttyConfigValueConvertibleBridge>: DynamicProperty where Bridge.Value == Value, Bridge.UnderlyingValue == Value.UnderlyingValue {
        static func getValue(from cfg: ghostty_config_t, key: String, readDefaultValue: Bool) -> Value? {
            var v: Bridge.UnderlyingValue.GhosttyValue?
            // finalise a temporary config to get default values
            let tempCfg = ghostty_config_clone(cfg)
            if readDefaultValue {
                ghostty_config_finalize(tempCfg)
            }

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
                let storedValue = instance[keyPath: storageKeyPath].storage.value ?? Value(underlyingValue: Value.UnderlyingValue(ghosttyValue: nil))

                if let value = instance[keyPath: storageKeyPath].storage.value {
                    return value
                }
                let info = instance[keyPath: storageKeyPath].info
                guard let cfg = instance.config else {
                    return storedValue
                }
                guard let newValue = getValue(from: cfg, key: info.key, readDefaultValue: info.readDefaultValue) else {
                    return storedValue
                }
                instance[keyPath: storageKeyPath].storage.value = newValue
                return newValue
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
                for value in underlyingValue.representedValues(for: key) {
                    ghostty_config_set(cfg, key, UInt(key.count), value, UInt(value.count))
                }
                if info.reloadOnSet {
                    DispatchQueue.main.async {
                        instance.reload(for: nil)
                    }
                }
            }
        }

        struct Info: Identifiable {
            var id: String { key }
            let key: String
            let reloadOnSet: Bool
            let readDefaultValue: Bool
        }

        @available(*, unavailable,
                   message: "@ConfigEntry can only be applied to GhosttyConfig")
        var wrappedValue: Value {
            get { fatalError() }
            set { fatalError() }
        }

        private var reloadSignal: PassthroughSubject<Void, Never> = .init()
        private var storage = CurrentValueSubject<Value?, Never>(nil)
        @State private var info: Info

        var key: String {
            info.key
        }

        var projectedValue: AnyPublisher<Value, Never> {
            storage.map({ $0 ?? Value(underlyingValue: Value.UnderlyingValue(ghosttyValue: nil)) }).eraseToAnyPublisher()
        }

        init(_ key: String, reload: Bool, readDefaultValue: Bool, bridge _: Bridge.Type) {
            info = .init(key: key, reloadOnSet: reload, readDefaultValue: readDefaultValue)
        }
    }
}

extension Ghostty.ConfigEntry where Bridge == TollFreeBridge<Value> {
    init(_ key: String, reload: Bool = true, readDefaultValue: Bool = true) {
        self.init(key, reload: reload, readDefaultValue: readDefaultValue, bridge: Bridge.self)
    }
}

extension Ghostty.ConfigEntry where Bridge == GeneralGhosttyValueBridge<Value, Value.UnderlyingValue> {
    init(parsing key: String, reload: Bool = true, readDefaultValue: Bool = true) {
        self.init(key, reload: reload, readDefaultValue: readDefaultValue, bridge: Bridge.self)
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

extension Optional: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable where Wrapped: GhosttyConfigValueConvertible & GhosttyConfigValueBridgeable {
    typealias GhosttyValue = Wrapped.GhosttyValue
    init(ghosttyValue: GhosttyValue?) {
        guard let pointer = ghosttyValue else {
            self = .none
            return
        }
        self = .some(Wrapped(ghosttyValue: pointer))
    }

    func representedValues(for key: String) -> [String] {
        self?.representedValues(for: key) ?? []
    }
}

extension String: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = UnsafePointer<UInt8>
    init(ghosttyValue: GhosttyValue?) {
        guard let p = ghosttyValue else {
            self = ""
            return
        }
        // If you want extra safety, you can use `String(validatingUTF8:) ?? ""`
        self = String(cString: p)
    }

    func representedValues(for key: String) -> [String] {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        } else {
            return [trimmed]
        }
    }
}

extension Bool: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = Self

    init(ghosttyValue: Bool?) {
        self = ghosttyValue ?? false
    }

    func representedValues(for key: String) -> [String] {
        ["\(self)"]
    }
}

extension UInt: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = Self
    init(ghosttyValue: UInt?) {
        self = ghosttyValue ?? .zero
    }

    func representedValues(for key: String) -> [String] {
        ["\(self)"]
    }
}

/// `f32`
extension Float: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = Self

    init(ghosttyValue: GhosttyValue?) {
        self = ghosttyValue ?? 0
    }

    func representedValues(for key: String) -> [String] {
        [formatted(.number.precision(.fractionLength(3)).grouping(.never))]
    }
}

/// `f64`
extension Double: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = Self
    typealias UnderlyingValue = Float

    init(ghosttyValue: GhosttyValue?) {
        self = ghosttyValue ?? 0
    }

    func representedValues(for key: String) -> [String] {
        [formatted(.number.precision(.fractionLength(3)).grouping(.never))]
    }

    init(underlyingValue: Float) {
        self = Double(underlyingValue)
    }

    var underlyingValue: Float {
        Float(self)
    }
}

extension Color: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
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

    func representedValues(for key: String) -> [String] {
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

extension Array: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable where Element == Ghostty.RepeatableItem {
    typealias GhosttyValue = ghostty_config_repeatable_item_list_s

    init(ghosttyValue: ghostty_config_repeatable_item_list_s?) {
        guard let list = ghosttyValue else {
            self = []
            return
        }
        self = .init(list)
    }

    func representedValues(for key: String) -> [String] {
        map {
            if !$0.key.isEmpty, key != $0.key {
                // like font-codepoint-map, font-variation
                return "\($0.key)=\($0.value)"
            } else {
                // like font-family
                return $0.value
            }
        }
    }
}

extension Ghostty.AutoUpdateChannel: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = String.GhosttyValue

    init(ghosttyValue: String.GhosttyValue?) {
        let rawValue = String(ghosttyValue: ghosttyValue)
        self = Self(rawValue: rawValue) ?? .stable
    }

    func representedValues(for key: String) -> [String] {
        [rawValue]
    }
}
