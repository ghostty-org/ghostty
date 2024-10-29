import GhosttyKit

extension Ghostty {
    struct Action {}
}

extension Ghostty.Action {
    struct MoveTab {
        let amount: Int

        init(c: ghostty_action_move_tab_s) {
            self.amount = c.amount
        }
    }
}
