import Darwin
import Foundation

/// Synchronous disk boundary. The UI owns one instance on the main actor.
final class SSHSessionFile {
    let url: URL
    private var snapshot: Data?
    private var loaded = false

    init(url: URL) { self.url = url }

    func load() throws -> SSHSessionDocument {
        loaded = false
        let data = try currentData()
        let document: SSHSessionDocument
        if let data {
            document = try JSONDecoder().decode(SSHSessionDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                throw SSHError.message("This SSH session file was created by a newer version. It will not be overwritten.")
            }
            guard Set(document.profiles.map(\.id)).count == document.profiles.count,
                  Set(document.folders.map(\.id)).count == document.folders.count else {
                throw SSHError.message("The SSH session file contains duplicate identifiers.")
            }
        } else {
            document = SSHSessionDocument()
        }
        snapshot = data
        loaded = true
        return document
    }

    func save(_ document: SSHSessionDocument) throws {
        guard loaded else { throw SSHError.message("Reload the SSH session file before saving.") }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        guard try currentData() == snapshot else {
            throw SSHError.message("SSH sessions changed on disk. Reload before saving; your edit has not been written.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let temporary = directory.appendingPathComponent(".ssh-sessions-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        snapshot = data
    }

    private func currentData() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}
