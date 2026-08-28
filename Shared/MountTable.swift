import Foundation
import Darwin

/// One row of the kernel's mount table.
public struct MountTableEntry: Sendable {
    public var mountPoint: String
    /// For a normal device mount this is `/dev/disk4s1`; for a FUSE-T NFS-backed
    /// mount it is something like `localhost:/Untitled`, which is exactly why the
    /// device a FUSE mount belongs to has to be recovered from the ntfs-3g process
    /// arguments rather than from here.
    public var mountedFrom: String
    public var fsTypeName: String
    public var isReadOnly: Bool
    public var totalBytes: UInt64
    public var freeBytes: UInt64

    public var usedBytes: UInt64 { totalBytes >= freeBytes ? totalBytes - freeBytes : 0 }
}

public enum MountTable {
    public static func current() -> [MountTableEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return MountTableEntry(
                mountPoint: string(from: &entry.f_mntonname),
                mountedFrom: string(from: &entry.f_mntfromname),
                fsTypeName: string(from: &entry.f_fstypename),
                isReadOnly: (entry.f_flags & UInt32(MNT_RDONLY)) != 0,
                totalBytes: UInt64(entry.f_blocks) * UInt64(entry.f_bsize),
                freeBytes: UInt64(entry.f_bavail) * UInt64(entry.f_bsize))
        }
    }

    public static func entry(atMountPoint path: String) -> MountTableEntry? {
        current().first { $0.mountPoint == path }
    }

    /// The mount macOS made for a device, if any. Only finds real device mounts —
    /// which is what we want when looking for the built-in read-only NTFS mount.
    public static func entry(forDevice bsdName: String) -> MountTableEntry? {
        guard let devicePath = BSDName.devicePath(bsdName) else { return nil }
        return current().first { $0.mountedFrom == devicePath }
    }

    public static func isMountPoint(_ path: String) -> Bool {
        current().contains { $0.mountPoint == path }
    }

    private static func string<T>(from tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}

// MARK: - Process inspection

public struct RunningProcess: Sendable {
    public var pid: pid_t
    public var executablePath: String
    public var arguments: [String]
}

/// Finds ntfs-3g processes by walking the kernel process table.
///
/// This is how the app can honestly answer "are there orphaned FUSE processes?"
/// after an eject, and how a mount point is recovered for a device even if the
/// helper was restarted since the mount was made.
public enum ProcessTable {
    public static func processes(named executableName: String) -> [RunningProcess] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, u_int(name.count - 1), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        // The table can grow between the sizing call and the fetch; ask for extra room.
        size += MemoryLayout<kinfo_proc>.stride * 32
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        let fetched: Int32 = procs.withUnsafeMutableBufferPointer { buffer in
            sysctl(&name, u_int(name.count - 1), buffer.baseAddress, &size, nil, 0)
        }
        guard fetched == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [RunningProcess] = []
        for index in 0..<min(actualCount, capacity) {
            let pid = procs[index].kp_proc.p_pid
            guard pid > 0 else { continue }
            var comm = procs[index].kp_proc.p_comm
            let shortName = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            // p_comm is truncated to 16 chars, so match on a prefix and confirm below.
            guard executableName.hasPrefix(shortName) || shortName.hasPrefix(executableName) else {
                continue
            }
            guard let argv = arguments(of: pid), let executable = argv.first else { continue }
            guard (executable as NSString).lastPathComponent == executableName else { continue }
            results.append(RunningProcess(pid: pid,
                                          executablePath: executable,
                                          arguments: Array(argv.dropFirst())))
        }
        return results
    }

    /// Reads `KERN_PROCARGS2` for a pid.
    ///
    /// Returns the executable path followed by the arguments — argv[0] is dropped,
    /// because the kernel repeats the executable path there and a caller looking for
    /// ntfs-3g's first positional argument would otherwise find the program name.
    public static func arguments(of pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxName, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(argMax))
        var size = Int(argMax)
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            // EINVAL here usually just means the process exited; not worth reporting.
            return nil
        }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc > 0 else { return nil }

        var strings: [String] = []
        var index = MemoryLayout<Int32>.size
        // argv[0] is preceded by the executable path, then NUL padding.
        var current = [CChar]()
        var sawExecutablePath = false
        while index < size {
            let byte = buffer[index]
            index += 1
            if byte != 0 {
                current.append(byte)
                continue
            }
            if current.isEmpty {
                // Padding between the executable path and argv[0].
                continue
            }
            let value = String(decoding: current.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            current.removeAll(keepingCapacity: true)
            if !sawExecutablePath {
                sawExecutablePath = true
                strings.append(value)
                continue
            }
            strings.append(value)
            // The executable path plus argc argv entries is everything we need.
            if strings.count >= Int(argc) + 1 { break }
        }
        guard !strings.isEmpty else { return nil }
        // strings == [executablePath, argv[0], argv[1], ...]; argv[0] is a duplicate
        // of the program name and is not an argument.
        if strings.count > 1 { strings.remove(at: 1) }
        return strings
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
