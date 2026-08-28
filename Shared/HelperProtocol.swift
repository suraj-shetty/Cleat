import Foundation

/// Identifiers shared by the app and the privileged helper.
public enum HelperConstants {
    /// Mach service the helper vends. Must match `MachServices` in the launchd plist.
    public static let machServiceName = "com.cleat.helper"
    /// File name of the launchd plist inside `Contents/Library/LaunchDaemons`.
    public static let launchdPlistName = "com.cleat.helper.plist"
    /// Bumped whenever the helper's wire protocol or behaviour changes so the app
    /// can force a re-registration of a stale on-disk helper.
    public static let version = "1.0.0"
    /// Bundle identifier of the only app allowed to talk to the helper.
    public static let clientBundleIdentifier = "com.cleat.app"
}

/// The XPC surface of the privileged helper.
///
/// Everything is funnelled through a single JSON-encoded request/response pair so
/// that no `NSSecureCoding` class allow-lists have to be maintained on either side,
/// and so the helper can validate the entire request shape in one place.
@objc public protocol CleatHelperProtocol {
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
    func perform(_ requestJSON: Data, reply: @escaping @Sendable (Data) -> Void)
}

// MARK: - Requests

public enum HelperRequest: Codable, Sendable {
    /// Unmount whatever macOS mounted (its read-only NTFS driver) and re-mount the
    /// device read/write through ntfs-3g + FUSE-T.
    case mountReadWrite(MountRequest)
    /// Unmount the FUSE mount for a device without ejecting the hardware.
    case unmount(UnmountRequest)
    /// Unmount the FUSE mount and then eject the whole physical disk.
    case eject(UnmountRequest)
    /// Report on ntfs-3g processes the helper has spawned, and any it can still see.
    case activeMounts

    /// How long the app waits for a reply before giving up on this request.
    ///
    /// Generous for mounting: the helper unmounts the OS driver, probes the boot
    /// sector, and then polls for the FUSE mount to appear, which on a large or
    /// unclean volume is legitimately slow. The point is to bound the wait, not to
    /// race it.
    public var timeout: TimeInterval {
        switch self {
        case .mountReadWrite: return 120
        case .unmount, .eject: return 90
        case .activeMounts: return 30
        }
    }
}

public struct MountRequest: Codable, Sendable {
    /// BSD identifier of the *partition*, e.g. `disk4s1`. Never a path.
    public var bsdName: String
    /// Desired volume name. Used for the mount point and `volname=`; sanitised again
    /// by the helper before it reaches any argument list.
    public var volumeName: String
    /// uid/gid the mounted files should be owned by (the console user).
    public var ownerUID: uid_t
    public var ownerGID: gid_t
    /// `fskit` on macOS 26+, `nfs` on macOS 15. Chosen by the app, re-validated by the helper.
    public var backend: FUSEBackend
    /// Absolute path to the ntfs-3g binary the app verified is linked against FUSE-T.
    public var ntfs3gPath: String
    /// When true the helper refuses to unmount a volume that has open files instead
    /// of forcing it. Always true unless the user explicitly confirmed a force.
    public var refuseIfBusy: Bool

    public init(bsdName: String,
                volumeName: String,
                ownerUID: uid_t,
                ownerGID: gid_t,
                backend: FUSEBackend,
                ntfs3gPath: String,
                refuseIfBusy: Bool = true) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
        self.backend = backend
        self.ntfs3gPath = ntfs3gPath
        self.refuseIfBusy = refuseIfBusy
    }
}

public struct UnmountRequest: Codable, Sendable {
    public var bsdName: String
    /// Path the helper previously mounted. Re-derived by the helper if absent.
    public var mountPoint: String?
    public var refuseIfBusy: Bool

    public init(bsdName: String, mountPoint: String?, refuseIfBusy: Bool = true) {
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.refuseIfBusy = refuseIfBusy
    }
}

public enum FUSEBackend: String, Codable, Sendable {
    case fskit
    case nfs

    /// FSKit is only available from macOS 26; everything older uses the NFSv4 loopback.
    public static var preferredForCurrentOS: FUSEBackend {
        if #available(macOS 26.0, *) { return .fskit }
        return .nfs
    }
}

// MARK: - Responses

public enum HelperResponse: Codable, Sendable {
    case mounted(MountResult)
    case unmounted(bsdName: String)
    case activeMounts([ActiveMount])
    case failure(HelperFailure)
}

public struct MountResult: Codable, Sendable {
    public var bsdName: String
    public var mountPoint: String
    public var backend: FUSEBackend
    public var pid: Int32

    public init(bsdName: String, mountPoint: String, backend: FUSEBackend, pid: Int32) {
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.backend = backend
        self.pid = pid
    }
}

public struct ActiveMount: Codable, Sendable {
    public var bsdName: String
    public var mountPoint: String
    public var pid: Int32
    public var backend: FUSEBackend

    public init(bsdName: String, mountPoint: String, pid: Int32, backend: FUSEBackend) {
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.pid = pid
        self.backend = backend
    }
}

/// A helper-side failure, flattened so it survives the JSON round trip.
public struct HelperFailure: Codable, Sendable, Error {
    public enum Kind: String, Codable, Sendable {
        case invalidRequest
        case notAnNTFSVolume
        case deviceNotFound
        case volumeBusy
        case unmountFailed
        case mountPointUnavailable
        case ntfs3gMissing
        case ntfs3gFailed
        case mountDidNotAppear
        case ejectFailed
        case internalError
    }

    public var kind: Kind
    public var message: String
    /// stderr/stdout captured from ntfs-3g or diskutil, when there is any.
    public var detail: String?

    public init(kind: Kind, message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }
}

// MARK: - Validation

public enum BSDName {
    /// Matches `disk4`, `disk4s1`, `disk4s1s1` and nothing else.
    ///
    /// Every path that reaches an argument vector or a device node is built from a
    /// value that passed through here, so a volume label can never turn into a flag,
    /// a path traversal, or a second argument.
    public static func isValid(_ name: String) -> Bool {
        guard name.count >= 5, name.count <= 32 else { return false }
        guard name.hasPrefix("disk") else { return false }
        var rest = Substring(name.dropFirst(4))
        guard let firstRun = takeDigits(&rest), firstRun else { return false }
        while !rest.isEmpty {
            guard rest.first == "s" else { return false }
            rest = rest.dropFirst()
            guard let run = takeDigits(&rest), run else { return false }
        }
        return true
    }

    private static func takeDigits(_ s: inout Substring) -> Bool? {
        var count = 0
        while let c = s.first, c.isASCII, c.isNumber {
            s = s.dropFirst()
            count += 1
            if count > 6 { return false }
        }
        return count > 0
    }

    public static func devicePath(_ name: String) -> String? {
        guard isValid(name) else { return nil }
        return "/dev/\(name)"
    }

    public static func rawDevicePath(_ name: String) -> String? {
        guard isValid(name) else { return nil }
        return "/dev/r\(name)"
    }

    /// `disk4s1` -> `disk4`. Used to eject the whole device.
    public static func wholeDisk(of name: String) -> String? {
        guard isValid(name) else { return nil }
        guard let sIndex = name.dropFirst(4).firstIndex(of: "s") else { return name }
        return String(name[name.startIndex..<sIndex])
    }
}

public enum VolumeNameSanitizer {
    /// Produces a mount-point-safe name: no separators, no leading dot or dash, no
    /// control characters, bounded length. Falls back to a stable default.
    public static func sanitize(_ raw: String, fallback: String = "NTFS Volume") -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:\0")
            .union(.controlCharacters)
            .union(.illegalCharacters)
        var cleaned = raw.components(separatedBy: disallowed).joined(separator: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
