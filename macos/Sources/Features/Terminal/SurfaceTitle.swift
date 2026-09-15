import Combine

/// A title has its own publisher, but is not a change to terminal content.
/// Keep Published's delivery semantics for existing title subscribers without
/// forwarding every OSC title update to SurfaceView.objectWillChange.
@propertyWrapper
struct SurfaceTitle {
    private final class Storage {
        @Published var value: String
        init(_ value: String) { self.value = value }
    }

    private let storage: Storage

    init(wrappedValue: String) { storage = Storage(wrappedValue) }

    var wrappedValue: String {
        get { storage.value }
        nonmutating set {
            guard storage.value != newValue else { return }
            storage.value = newValue
        }
    }

    var projectedValue: Published<String>.Publisher { storage.$value }
}
