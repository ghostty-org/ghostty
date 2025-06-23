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

extension Array where Element == String {
    /// Executes a closure with an array of C string pointers.
    func withCStrings<T>(_ body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
        // Handle empty array
        if isEmpty {
            return try body([])
        }

        // Recursive helper to process strings
        func helper(index: Int, accumulated: [UnsafePointer<Int8>?], body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
            if index == count {
                return try body(accumulated)
            }
            
            return try self[index].withCString { cStr in
                var newAccumulated = accumulated
                newAccumulated.append(cStr)
                return try helper(index: index + 1, accumulated: newAccumulated, body: body)
            }
        }

        return try helper(index: 0, accumulated: [], body: body)
    }
}
