import Foundation
import Darwin

final class AgentEventTailer {
    private let url: URL
    private let queue = DispatchQueue(label: "dev.sidequery.Ghostree.agent-events-tailer")
    private let onEvent: (AgentLifecycleEvent) -> Void

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var readOffset: UInt64 = 0
    private var buffer = Data()

    init(url: URL, onEvent: @escaping (AgentLifecycleEvent) -> Void) {
        self.url = url
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startLocked()
        }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil

            if fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }

            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func startLocked() {
        if source != nil { return }

        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            fileHandle = try FileHandle(forReadingFrom: url)
            if let fileHandle {
                readOffset = (try? fileHandle.seekToEnd()) ?? 0
            } else {
                readOffset = 0
            }
        } catch {
            fileHandle = nil
            return
        }

        fileDescriptor = open(url.path, O_EVTONLY)
        if fileDescriptor < 0 {
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.restartLocked()
                return
            }
            self.readAppendedLocked()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
    }

    private func restartLocked() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        try? fileHandle?.close()
        fileHandle = nil
        readOffset = 0
        buffer.removeAll(keepingCapacity: true)
        startLocked()
    }

    private func readAppendedLocked() {
        guard let fileHandle else { return }

        do {
            try fileHandle.seek(toOffset: readOffset)
            let data = try fileHandle.readToEnd() ?? Data()
            if data.isEmpty { return }
            readOffset += UInt64(data.count)
            buffer.append(data)
            drainLinesLocked()
        } catch {
            return
        }
    }

    private func drainLinesLocked() {
        while true {
            guard let newlineRange = buffer.range(of: Data([0x0a])) else { return }
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let event = Self.parseLineData(lineData) else { return }
        onEvent(event)
    }

    static func parseLineData(_ lineData: Data) -> AgentLifecycleEvent? {
        guard !lineData.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: lineData),
              let dict = obj as? [String: Any] else { return nil }
        guard let eventTypeRaw = dict["eventType"] as? String,
              let eventType = AgentLifecycleEventType(rawValue: eventTypeRaw) else { return nil }
        guard let cwd = dict["cwd"] as? String else { return nil }

        var timestamp = Date()
        if let ts = dict["timestamp"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            if let parsed = fmt.date(from: ts) {
                timestamp = parsed
            }
        }

        return AgentLifecycleEvent(timestamp: timestamp, eventType: eventType, cwd: cwd)
    }
}
