import Foundation
import DiskArbitration

/// A DiskArbitration error, decoded far enough to distinguish "the volume is busy"
/// from everything else — the distinction the whole eject-safety story rests on.
public struct DAError: Error, Sendable {
    public var status: DAReturn
    public var localizedMessage: String

    /// DiskArbitration reports POSIX failures as `0xC000 | errno` rather than as one
    /// of the `kDAReturn*` constants. macOS 26's FSKit-backed NTFS mounts take that
    /// path, so a busy volume arrives as `0xC010` (EBUSY) and not as `kDAReturnBusy`
    /// — decoding both is what keeps "refuse to unmount a busy volume" working.
    public var posixErrorCode: Int32? {
        let raw = UInt32(bitPattern: Int32(status))
        guard (raw & 0xFFFF_FF00) == 0x0000_C000 else { return nil }
        return Int32(raw & 0xFF)
    }

    public var isBusy: Bool {
        Int(status) == kDAReturnBusy || posixErrorCode == EBUSY
    }

    public var isNotMounted: Bool {
        Int(status) == kDAReturnNotMounted
            || posixErrorCode == EINVAL
    }

    public init(status: DAReturn, localizedMessage: String? = nil) {
        self.status = status
        self.localizedMessage = localizedMessage ?? DAError.describe(status)
    }

    private static func describe(_ status: DAReturn) -> String {
        let raw = UInt32(bitPattern: Int32(status))
        if (raw & 0xFFFF_FF00) == 0x0000_C000 {
            return String(cString: strerror(Int32(raw & 0xFF)))
        }
        switch Int(status) {
        case kDAReturnBusy: return "The volume is in use by another process."
        case kDAReturnNotMounted: return "The volume is not mounted."
        case kDAReturnNotPermitted: return "Not permitted to change this volume."
        case kDAReturnNotPrivileged: return "Insufficient privileges for this volume."
        case kDAReturnUnsupported: return "The operation is not supported for this disk."
        case kDAReturnBadArgument: return "Invalid disk identifier."
        case kDAReturnExclusiveAccess: return "Another process holds exclusive access."
        default: return "DiskArbitration error \(status)."
        }
    }
}

/// Synchronous wrapper around the DiskArbitration APIs we need.
///
/// Every entry point validates the BSD name first, so no caller can smuggle a path
/// or an option string in through a disk identifier.
public final class DiskArbitrationBridge: @unchecked Sendable {
    private let session: DASession
    private let queue = DispatchQueue(label: "com.cleat.diskarbitration", qos: .userInitiated)

    public init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
    }

    public var rawSession: DASession { session }
    public var callbackQueue: DispatchQueue { queue }

    // MARK: Description

    public func description(ofBSDName bsdName: String) -> [String: Any]? {
        guard BSDName.isValid(bsdName) else { return nil }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            return nil
        }
        return DADiskCopyDescription(disk) as? [String: Any]
    }

    // MARK: Unmount

    /// Unmounts a volume. `whole` unmounts every volume on the physical disk, which
    /// is what has to happen before the hardware can be ejected.
    ///
    /// `force` maps to `MNT_FORCE` and is never passed unless a caller has explicitly
    /// asked for it after the user confirmed; without it a busy volume simply fails
    /// with `kDAReturnBusy` and nothing is torn out from under an open file.
    public func unmount(bsdName: String,
                        whole: Bool = false,
                        force: Bool = false,
                        timeout: TimeInterval = 30) throws {
        guard BSDName.isValid(bsdName) else {
            throw DAError(status: DAReturn(kDAReturnBadArgument))
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw DAError(status: DAReturn(kDAReturnBadArgument))
        }
        var options: DADiskUnmountOptions = DADiskUnmountOptions(kDADiskUnmountOptionDefault)
        if whole { options |= DADiskUnmountOptions(kDADiskUnmountOptionWhole) }
        if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }

        let result = Waiter()
        let context = Unmanaged.passRetained(result).toOpaque()
        DADiskUnmount(disk, options, { _, dissenter, context in
            guard let context else { return }
            let waiter = Unmanaged<Waiter>.fromOpaque(context).takeRetainedValue()
            waiter.finish(dissenter: dissenter)
        }, context)

        try result.wait(timeout: timeout)
    }

    // MARK: Eject

    public func eject(bsdName: String, timeout: TimeInterval = 30) throws {
        guard BSDName.isValid(bsdName) else {
            throw DAError(status: DAReturn(kDAReturnBadArgument))
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw DAError(status: DAReturn(kDAReturnBadArgument))
        }
        let result = Waiter()
        let context = Unmanaged.passRetained(result).toOpaque()
        DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
            guard let context else { return }
            let waiter = Unmanaged<Waiter>.fromOpaque(context).takeRetainedValue()
            waiter.finish(dissenter: dissenter)
        }, context)

        try result.wait(timeout: timeout)
    }
}

/// Bridges a DiskArbitration completion callback back to the calling thread.
private final class Waiter: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var error: DAError?

    func finish(dissenter: DADissenter?) {
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            let message = DADissenterGetStatusString(dissenter) as String?
            lock.lock()
            error = DAError(status: status, localizedMessage: message)
            lock.unlock()
        }
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw DAError(status: DAReturn(kDAReturnBusy),
                          localizedMessage: "The operation timed out waiting for DiskArbitration.")
        }
        lock.lock()
        let captured = error
        lock.unlock()
        if let captured { throw captured }
    }
}
