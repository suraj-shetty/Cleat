import Foundation

/// Builds and parses ntfs-3g command lines.
///
/// Kept apart from the mount logic because both directions matter: the arguments
/// have to be safe to build from a user-supplied volume label, and they have to be
/// parseable again later, since reading them back out of the process table is the
/// only way to learn which device a live FUSE mount belongs to.
public enum NTFS3GInvocation {

    /// `-o` takes a single comma-separated list, so a comma or an equals sign in a
    /// volume label would otherwise inject an option of the attacker's choosing.
    public static func optionSafeVolumeName(_ name: String) -> String {
        VolumeNameSanitizer.sanitize(name)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "=", with: " ")
    }

    public static func arguments(devicePath: String,
                                 mountPoint: String,
                                 volumeName: String,
                                 uid: uid_t,
                                 gid: gid_t,
                                 backend: FUSEBackend?) -> [String] {
        var options = [
            "local",
            "allow_other",
            "auto_xattr",
            "noatime",
            "uid=\(uid)",
            "gid=\(gid)",
            "umask=022",
            "volname=\(optionSafeVolumeName(volumeName))"
        ]
        if let backend { options.append("backend=\(backend.rawValue)") }
        return [devicePath, mountPoint, "-o", options.joined(separator: ",")]
    }

    /// Recovers `<device> <mountpoint>` from an ntfs-3g argument vector (argv[0]
    /// already removed). Flags and their values are skipped.
    public static func deviceAndMountPoint(from arguments: [String]) -> (device: String, mountPoint: String)? {
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            // The only ntfs-3g/FUSE flags that take a separate value.
            if argument == "-o" || argument == "-l" {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            positional.append(argument)
            index += 1
        }
        guard positional.count >= 2, positional[0].hasPrefix("/dev/") else { return nil }
        return (positional[0], positional[1])
    }
}
