extension String {
    func truncate(length: Int, trailing: String = "…") -> String {
        let maxLength = length - trailing.count
        guard maxLength > 0, !self.isEmpty, self.count > length else {
            return self
        }
        return self.prefix(maxLength) + trailing
    }

    #if canImport(AppKit)
    func temporaryFile(_ filename: String = "temp") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension("txt")
        let string = self
        try? string.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    #endif
}
