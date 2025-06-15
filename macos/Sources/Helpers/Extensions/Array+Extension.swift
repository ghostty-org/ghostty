extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
    
    /// Returns the index before i, with wraparound. Assumes i is a valid index.
    func indexWrapping(before i: Int) -> Int {
        if i == 0 {
            return count - 1
        }

        return i - 1
    }

    /// Returns the index after i, with wraparound. Assumes i is a valid index.
    func indexWrapping(after i: Int) -> Int {
        if i == count - 1 {
            return 0
        }

        return i + 1
    }
}
