import Combine
import GhosttyKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

protocol GhosttyConfigPersistProvider {
    func set(_ value: [String], for key: String)
    func get(for key: String) -> [String]?

    func export() async -> Data?
}

/// An object that has reference to a `ghostty_config_t`
protocol GhosttyConfigObject: AnyObject {
    var config: ghostty_config_t? { get }
    func reload()
    var persistProvider: GhosttyConfigPersistProvider? { get }
}

extension GhosttyConfigObject {
    var persistProvider: GhosttyConfigPersistProvider? { nil }
}

protocol GhosttyConfigValueConvertible {
    associatedtype GhosttyValue
    init(ghosttyValue: GhosttyValue?)
    init(persistValues: [String])
    func persistValues(for key: String) -> [String]
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

struct BinaryFloatingBridge<Value: BinaryFloatingPoint, UnderlyingValue: BinaryFloatingPoint & GhosttyConfigValueConvertible>: GhosttyConfigValueConvertibleBridge {
    static func convert(value: Value) -> UnderlyingValue {
        UnderlyingValue(value)
    }

    static func convert(underlying: UnderlyingValue) -> Value {
        Value(underlying)
    }
}

extension Ghostty {
    // `ghostty_config_clone` can only be done in main thread for now
    // so we just make it isolated to main actor,
    // and View/body updates should happen in main thread too
    @MainActor
    @propertyWrapper
    struct ConfigEntry<Value, UnderlyingValue, Bridge: GhosttyConfigValueConvertibleBridge>: DynamicProperty where Bridge.Value == Value, Bridge.UnderlyingValue == UnderlyingValue {
        static func getValue(from cfg: ghostty_config_t, provider: GhosttyConfigPersistProvider?, key: String, readDefaultValue: Bool) -> Value? {
            if let persistValues = provider?.get(for: key) {
                return Bridge.convert(underlying: Bridge.UnderlyingValue(persistValues: persistValues))
            }
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
            let underlying = Bridge.UnderlyingValue(ghosttyValue: v)
            // save
            provider?.set(underlying.persistValues(for: key), for: key)
            let value = Bridge.convert(underlying: underlying)
            return value
        }

        static subscript<T: GhosttyConfigObject>(
            _enclosingInstance instance: T,
            wrapped _: ReferenceWritableKeyPath<T, Value>,
            storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
        ) -> Value {
            get {
                if let value = instance[keyPath: storageKeyPath].storage.value {
                    return value
                }
                let defaultValue = Bridge.convert(underlying: Bridge.UnderlyingValue(ghosttyValue: nil))
                let info = instance[keyPath: storageKeyPath].info
                guard let cfg = instance.config else {
                    return defaultValue
                }
                guard let newValue = getValue(from: cfg, provider: instance.persistProvider, key: info.key, readDefaultValue: info.readDefaultValue) else {
                    return defaultValue
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
                let info = instance[keyPath: storageKeyPath].info
                let key = info.key
                let underlyingValue = Bridge.convert(value: newValue)
                instance.persistProvider?.set(underlyingValue.persistValues(for: key), for: key)
                if info.reloadOnSet {
                    instance.reload()
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
            storage.map {
                $0 ?? Bridge.convert(underlying: Bridge.UnderlyingValue(ghosttyValue: nil))
            }.eraseToAnyPublisher()
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

extension Ghostty.ConfigEntry where Bridge == BinaryFloatingBridge<Value, UnderlyingValue> {
    init(_ key: String, parsing: Bridge.UnderlyingValue.Type, reload: Bool = true, readDefaultValue: Bool = true) {
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

extension Optional: GhosttyConfigValueConvertible where Wrapped: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Wrapped.GhosttyValue
    init(ghosttyValue: GhosttyValue?) {
        guard let pointer = ghosttyValue else {
            self = .none
            return
        }
        self = .some(Wrapped(ghosttyValue: pointer))
    }

    init(persistValues: [String]) {
        self = .some(Wrapped(persistValues: persistValues))
    }

    func persistValues(for key: String) -> [String] {
        self?.persistValues(for: key) ?? []
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

    init(persistValues: [String]) {
        self = persistValues.first ?? ""
    }

    func persistValues(for key: String) -> [String] {
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

    init(persistValues: [String]) {
        self = persistValues.first.flatMap(Bool.init(_:)) ?? false
    }

    func persistValues(for key: String) -> [String] {
        ["\(self)"]
    }
}

extension UInt: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self
    init(ghosttyValue: UInt?) {
        self = ghosttyValue ?? .zero
    }

    init(persistValues: [String]) {
        self = persistValues.first.flatMap(Self.init(_:)) ?? .zero
    }

    func persistValues(for key: String) -> [String] {
        ["\(self)"]
    }
}

/// `f32`
extension Float: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self

    init(ghosttyValue: GhosttyValue?) {
        self = ghosttyValue ?? 0
    }

    init(persistValues: [String]) {
        self = persistValues.first.flatMap(Self.init(_:)) ?? .zero
    }

    func persistValues(for key: String) -> [String] {
        [formatted(.number.precision(.fractionLength(3)).grouping(.never))]
    }
}

/// `f64`
extension Double: GhosttyConfigValueConvertible {
    typealias GhosttyValue = Self
    typealias UnderlyingValue = Float

    init(ghosttyValue: GhosttyValue?) {
        self = ghosttyValue ?? 0
    }

    init(persistValues: [String]) {
        self = persistValues.first.flatMap(Self.init(_:)) ?? .zero
    }

    func persistValues(for key: String) -> [String] {
        [formatted(.number.precision(.fractionLength(3)).grouping(.never))]
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

    init(persistValues: [String]) {
        let osColor = persistValues.first.flatMap(OSColor.init(hex:)) ?? .clear
        self = Color(osColor)
    }

    func persistValues(for key: String) -> [String] {
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

    init(persistValues: [String]) {
        self = persistValues.compactMap {
            let parts = $0.split(separator: "=")
            if parts.count == 2 {
                return Element(key: String(parts[0]), value: String(parts[1]))
            } else if parts.count == 1 {
                return Element(key: "", value: String(parts[0]))
            } else {
                return nil
            }
        }
    }

    func persistValues(for key: String) -> [String] {
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

extension Ghostty.AutoUpdateChannel: GhosttyConfigValueConvertible {
    typealias GhosttyValue = String.GhosttyValue

    init(ghosttyValue: String.GhosttyValue?) {
        let rawValue = String(ghosttyValue: ghosttyValue)
        self = Self(rawValue: rawValue) ?? .stable
    }

    init(persistValues: [String]) {
        self = persistValues.first.flatMap(Self.init(rawValue:)) ?? .stable
    }

    func persistValues(for key: String) -> [String] {
        [rawValue]
    }
}

extension Ghostty.Theme: GhosttyConfigValueConvertible {
    typealias GhosttyValue = ghostty_config_theme_s

    init(ghosttyValue: GhosttyValue?) {
        if let theme = ghosttyValue {
            light = String(bytes: UnsafeBufferPointer(start: theme.light, count: theme.light_len).map(UInt8.init(_:)), encoding: .utf8) ?? ""
            dark = String(bytes: UnsafeBufferPointer(start: theme.dark, count: theme.dark_len).map(UInt8.init(_:)), encoding: .utf8) ?? ""
        }
    }

    init(persistValues: [String]) {
        guard let first = persistValues.first else {
            self = Self()
            return
        }
        let parts = first.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].hasPrefix("light:"), parts[1].hasPrefix("dark:") {
            light = parts[0].replacingOccurrences(of: "light:", with: "")
            dark = parts[1].replacingOccurrences(of: "dark:", with: "")
        } else if parts.count == 1 {
            light = String(parts[0])
            dark = light
        } else {
            self = Self()
        }
    }

    func persistValues(for key: String) -> [String] {
        guard light != dark, !light.isEmpty, !dark.isEmpty else {
            return [light.isEmpty ? dark : light]
        }
        return ["light:\(light),dark:\(dark)"]
    }
}

extension Ghostty.FontSyntheticStyle: GhosttyConfigValueConvertible {
    typealias GhosttyValue = String

    init(ghosttyValue: String?) {
        guard let ghosttyValue else {
            self.init()
            return
        }
        let parts = ghosttyValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var style = Ghostty.FontSyntheticStyle()
        if parts.contains("no-bold") || parts.contains("false") {
            style.bold = false
        }
        if parts.contains("no-italic") || parts.contains("false") {
            style.italic = false
        }
        if parts.contains("no-bold-italic") || parts.contains("false") {
            style.boldItalic = false
        }
        self = style
    }

    init(persistValues: [String]) {
        self.init(ghosttyValue: persistValues.first)
    }

    var representedValue: String {
        if bold, italic, boldItalic {
            return "true"
        } else if !bold, !italic, !boldItalic {
            return "false"
        } else {
            var result: [String] = []
            if !bold {
                result.append("no-bold")
            }
            if !italic {
                result.append("no-italic")
            }
            if !boldItalic {
                result.append("no-bold-italic")
            }
            return result.joined(separator: ",")
        }
    }

    func persistValues(for key: String) -> [String] {
        [representedValue]
    }
}
