import Foundation

extension UndoManager {
    /// A Boolean value that indicates whether the undo manager is currently performing
    /// either an undo or redo operation.
    var isUndoingOrRedoing: Bool {
        isUndoing || isRedoing
    }

    /// Temporarily disables undo registration while executing the provided handler.
    ///
    /// This method provides a convenient way to perform operations without recording them
    /// in the undo stack. It ensures that undo registration is properly re-enabled even
    /// if the handler throws an error.
    func disableUndoRegistration(handler: () -> Void) {
        disableUndoRegistration()
        handler()
        enableUndoRegistration()
    }
}
