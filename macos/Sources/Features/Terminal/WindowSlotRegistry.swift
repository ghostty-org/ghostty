import Cocoa
import GhosttyKit

/// A process-wide registry mapping 1-based window slot numbers to the
/// terminal controllers that currently occupy them.
///
/// Slots are used by the `goto_window:N` binding action to jump to a
/// specific terminal window by a stable number, independent of z-order
/// or creation order. The registry guarantees:
///
///   - Slots start at 1 and are always the lowest integer not currently
///     in use. When a new window is created, it is assigned to the
///     lowest free slot.
///   - A slot is only released when its window closes. While a window
///     lives, its slot number does not change — this keeps keyboard
///     shortcuts stable.
///   - If a window in slot N closes, slot N becomes free and the next
///     new window will reuse it. Existing windows keep their numbers.
///
/// For example, opening windows A, B, C assigns slots 1, 2, 3. Closing
/// B frees slot 2. Opening a new window D assigns slot 2 (the lowest
/// free). A stays at 1, D at 2, C at 3.
///
/// ## Threading
///
/// All methods must be called on the main thread. Window lifecycle
/// callbacks (`windowDidLoad`, `windowWillClose`) and the action
/// handler both run on the main thread, so this matches their
/// callers. `dispatchPrecondition` enforces this — an off-main call
/// will trap in debug builds rather than silently risk a data race.
///
/// The registry stores weak references so a controller that is
/// deallocated without going through the normal close path does not
/// pin a slot, but the primary release path is explicit via
/// `release(_:from:)` in `windowWillClose`.
class WindowSlotRegistry {
    /// Shared process-wide registry. There is exactly one, matching the
    /// app's single running instance.
    static let shared = WindowSlotRegistry()

    /// Weak wrapper so the registry does not retain controllers.
    private struct WeakControllerBox {
        weak var controller: BaseTerminalController?
    }

    /// Slot number (1-based) → weak controller reference.
    private var slots: [Int: WeakControllerBox] = [:]

    private init() {}

    /// Claim the lowest free slot for the given controller. Returns the
    /// slot number that was assigned.
    ///
    /// If the controller is already in the registry (e.g. claim called
    /// twice), the existing slot is returned.
    @discardableResult
    func claim(_ controller: BaseTerminalController) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))

        // If this controller is already registered, return its slot.
        if let existing = slots.first(where: { $0.value.controller === controller }) {
            Ghostty.logger.debug("window slot claim: already-held slot=\(existing.key)")
            return existing.key
        }

        // Find the lowest free slot, starting at 1. Prune any stale weak
        // references we encounter along the way so dead slots get reused.
        var slot = 1
        while true {
            if let box = slots[slot] {
                if box.controller == nil {
                    slots.removeValue(forKey: slot)
                    break
                }
                slot += 1
                continue
            }
            break
        }
        slots[slot] = WeakControllerBox(controller: controller)
        Ghostty.logger.debug("window slot claimed: slot=\(slot) total=\(self.slots.count)")
        return slot
    }

    /// Release a slot. Only releases if the slot is currently held by
    /// the given controller — avoids double-release races if close
    /// notifications arrive in unexpected orders.
    func release(_ slot: Int, from controller: BaseTerminalController) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let box = slots[slot] else {
            Ghostty.logger.debug("window slot release: slot=\(slot) not found")
            return
        }
        // Only release if this controller still holds the slot or
        // the weak reference has already been nil'd.
        if box.controller === controller || box.controller == nil {
            slots.removeValue(forKey: slot)
            Ghostty.logger.debug("window slot released: slot=\(slot) total=\(self.slots.count)")
        } else {
            Ghostty.logger.debug("window slot release: slot=\(slot) held by different controller")
        }
    }

    /// Look up the controller in a given slot, pruning stale entries
    /// whose weak references have been released.
    func controller(forSlot slot: Int) -> BaseTerminalController? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let box = slots[slot] else {
            Ghostty.logger.debug("window slot lookup: slot=\(slot) empty (known=\(self.slots.keys.sorted()))")
            return nil
        }
        guard let controller = box.controller else {
            // Weak reference has gone. Clean up the dead slot.
            slots.removeValue(forKey: slot)
            Ghostty.logger.debug("window slot lookup: slot=\(slot) weakref-nil")
            return nil
        }
        Ghostty.logger.debug("window slot lookup: slot=\(slot) found")
        return controller
    }
}
