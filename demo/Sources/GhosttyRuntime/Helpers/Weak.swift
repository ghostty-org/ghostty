/// A wrapper that holds a weak reference to an object. This lets us create native containers
/// of weak references.
class Weak<T: AnyObject> {
    weak var value: T?

    init(_ value: T? = nil) {
        self.value = value
    }
}
