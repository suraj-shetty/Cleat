import Foundation

struct MountRecord: Codable, Sendable {
    var bsdName: String
    var mountPoint: String
    var backend: FUSEBackend
    var pid: Int32
}

/// Remembers what the helper mounted, so an unmount still works after the helper
/// has been restarted by launchd. The kernel mount table cannot answer "which
/// device is behind this FUSE mount", and the process table only answers it while
/// ntfs-3g is alive, so this file covers the gap.
final class HelperStateStore {
    private let lock = NSLock()
    private let url: URL
    private var records: [String: MountRecord]

    init() {
        let directory = URL(fileURLWithPath: "/Library/Application Support/Cleat", isDirectory: true)
        url = directory.appendingPathComponent("helper-state.json")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: MountRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func record(_ record: MountRecord) {
        lock.lock()
        records[record.bsdName] = record
        lock.unlock()
        persist()
    }

    func record(forBSDName bsdName: String) -> MountRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[bsdName]
    }

    func remove(bsdName: String) {
        lock.lock()
        records.removeValue(forKey: bsdName)
        lock.unlock()
        persist()
    }

    func prune(keeping live: Set<String>) {
        lock.lock()
        let stale = records.keys.filter { !live.contains($0) }
        for key in stale { records.removeValue(forKey: key) }
        lock.unlock()
        if !stale.isEmpty { persist() }
    }

    private func persist() {
        lock.lock()
        let snapshot = records
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
