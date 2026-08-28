import Foundation

/// One NTFS volume as the app understands it.
struct NTFSVolume: Identifiable, Sendable, Equatable {
    /// BSD identifier of the partition, e.g. `disk4s1`. Stable for the life of the
    /// connection and the only thing ever handed to the helper as a device.
    var bsdName: String
    /// DiskArbitration's volume UUID. Stable across reconnects, so this is the key
    /// the "always mount read/write" preference is stored under.
    var volumeUUID: String?
    var name: String
    var mediaSize: UInt64
    var isRemovable: Bool
    var isEjectable: Bool
    /// Where macOS mounted it with the built-in read-only driver, if it did.
    var readOnlyMountPoint: String?

    var state: State = .idle

    var id: String { bsdName }

    enum State: Sendable, Equatable {
        /// Not mounted by us. `readOnlyMountPoint` says whether macOS has it read-only.
        case idle
        case working(String)
        case mountedReadWrite(MountedInfo)
        case failed(String)
    }

    struct MountedInfo: Sendable, Equatable {
        var mountPoint: String
        var backend: FUSEBackend
        var pid: Int32
        var totalBytes: UInt64
        var freeBytes: UInt64
    }

    var devicePath: String { "/dev/\(bsdName)" }

    /// Stable key for per-volume preferences.
    ///
    /// DiskArbitration exposes a volume UUID for most filesystems, but not reliably
    /// for NTFS — macOS often reports none at all — so there is a fallback built from
    /// the three things about a drive that do not change between reconnects. Both
    /// forms are computable the moment the drive appears, without root and without
    /// mounting it, which is what makes "mount this one automatically" work on the
    /// very first notification.
    var identity: String {
        if let volumeUUID, !volumeUUID.isEmpty { return "uuid:\(volumeUUID)" }
        return "media:\(name)|\(mediaSize)"
    }

    var isMountedReadWrite: Bool {
        if case .mountedReadWrite = state { return true }
        return false
    }

    var isBusy: Bool {
        if case .working = state { return true }
        return false
    }

    var mountPoint: String? {
        if case .mountedReadWrite(let info) = state { return info.mountPoint }
        return readOnlyMountPoint
    }

    /// Capacity/free figures come from the live mount when there is one, and from
    /// the media size otherwise (a volume nobody has mounted cannot report free space).
    var totalBytes: UInt64 {
        if case .mountedReadWrite(let info) = state, info.totalBytes > 0 { return info.totalBytes }
        return mediaSize
    }

    var freeBytes: UInt64? {
        if case .mountedReadWrite(let info) = state { return info.freeBytes }
        if let readOnlyMountPoint, let entry = MountTable.entry(atMountPoint: readOnlyMountPoint) {
            return entry.freeBytes
        }
        return nil
    }

    var statusSummary: String {
        switch state {
        case .working(let message):
            return message
        case .mountedReadWrite(let info):
            let free = ByteCountFormatter.string(fromByteCount: Int64(info.freeBytes), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(info.totalBytes), countStyle: .file)
            return "Read/write · \(free) free of \(total)"
        case .failed(let message):
            return message
        case .idle:
            let total = ByteCountFormatter.string(fromByteCount: Int64(mediaSize), countStyle: .file)
            if readOnlyMountPoint != nil {
                return "Read-only (macOS driver) · \(total)"
            }
            return "Not mounted · \(total)"
        }
    }
}
