import Foundation
import Darwin
import os

/// Everything the privileged helper is actually allowed to do.
///
/// All work is funnelled through one serial queue by `HelperService`, so this type
/// assumes it is never re-entered concurrently for the same device.
/// Serialised by `HelperService`'s work queue, which is what makes the unchecked
/// conformance safe: no two operations ever run against this instance at once.
final class MountEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "com.cleat.helper", category: "MountEngine")
    private let diskArbitration: DiskArbitrationBridge?
    private let stateStore = HelperStateStore()

    init() {
        diskArbitration = DiskArbitrationBridge()
        if diskArbitration == nil {
            log.error("Could not create a DiskArbitration session; falling back to diskutil.")
        }
    }

    // MARK: - Mount

    func mountReadWrite(_ request: MountRequest) -> HelperResponse {
        guard BSDName.isValid(request.bsdName), let devicePath = BSDName.devicePath(request.bsdName) else {
            return .failure(HelperFailure(kind: .invalidRequest,
                                          message: "“\(request.bsdName)” is not a valid disk identifier."))
        }
        guard FileManager.default.fileExists(atPath: devicePath) else {
            return .failure(HelperFailure(kind: .deviceNotFound,
                                          message: "\(devicePath) is no longer present. Was the drive removed?"))
        }
        guard isExecutableNTFS3G(request.ntfs3gPath) else {
            return .failure(HelperFailure(kind: .ntfs3gMissing,
                                          message: "ntfs-3g was not found at \(request.ntfs3gPath).",
                                          detail: "Re-run the dependency setup, then try again."))
        }

        // Refuse to point a filesystem driver at anything that is not demonstrably NTFS.
        do {
            _ = try NTFSProbe.read(bsdName: request.bsdName)
        } catch NTFSProbe.ProbeError.notNTFS(let oemID) {
            return .failure(HelperFailure(kind: .notAnNTFSVolume,
                                          message: "\(devicePath) is not an NTFS volume.",
                                          detail: "Boot sector OEM identifier was “\(oemID)”."))
        } catch {
            // A busy raw device usually means macOS still has it mounted; unmount and retry
            // the probe after the unmount step below rather than failing outright here.
            log.notice("Initial NTFS probe of \(request.bsdName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }

        // Step 1: get macOS's read-only mount out of the way. A third-party FSKit
        // module or the built-in ntfs.fs will have claimed the device already, and
        // ntfs-3g cannot open it for writing while that mount exists.
        if let existing = MountTable.entry(forDevice: request.bsdName) {
            log.notice("Unmounting existing mount at \(existing.mountPoint, privacy: .public)")
            if let failure = unmountDevice(request.bsdName, force: !request.refuseIfBusy) {
                return .failure(failure)
            }
        }

        // Re-probe now that nothing holds the device open.
        do {
            _ = try NTFSProbe.read(bsdName: request.bsdName)
        } catch NTFSProbe.ProbeError.notNTFS(let oemID) {
            return .failure(HelperFailure(kind: .notAnNTFSVolume,
                                          message: "\(devicePath) is not an NTFS volume.",
                                          detail: "Boot sector OEM identifier was “\(oemID)”."))
        } catch {
            return .failure(HelperFailure(kind: .notAnNTFSVolume,
                                          message: "Could not read the NTFS boot sector on \(devicePath).",
                                          detail: String(describing: error)))
        }

        // Step 2: prepare a mount point we own.
        let displayName = VolumeNameSanitizer.sanitize(request.volumeName)
        let mountPoint: String
        do {
            mountPoint = try makeMountPoint(named: displayName,
                                            uid: request.ownerUID,
                                            gid: request.ownerGID)
        } catch {
            return .failure(HelperFailure(kind: .mountPointUnavailable,
                                          message: "Could not create a mount point for “\(displayName)”.",
                                          detail: String(describing: error)))
        }

        // Step 3: hand it to ntfs-3g. Try the requested backend, then fall back.
        let before = Set(MountTable.current().map(\.mountPoint))
        var attempts: [(FUSEBackend?, CommandResult)] = []
        var succeededBackend: FUSEBackend?

        for backend in backendAttemptOrder(preferred: request.backend) {
            let arguments = NTFS3GInvocation.arguments(devicePath: devicePath,
                                                      mountPoint: mountPoint,
                                                      volumeName: displayName,
                                                      uid: request.ownerUID,
                                                      gid: request.ownerGID,
                                                      backend: backend)
            log.notice("Running ntfs-3g with backend \(backend?.rawValue ?? "default", privacy: .public)")
            let result: CommandResult
            do {
                result = try ProcessRunner.run(request.ntfs3gPath,
                                               arguments: arguments,
                                               timeout: 45,
                                               environment: childEnvironment())
            } catch {
                attempts.append((backend, CommandResult(exitCode: -1,
                                                        standardOutput: "",
                                                        standardError: String(describing: error),
                                                        timedOut: false)))
                continue
            }
            attempts.append((backend, result))
            if result.succeeded, waitForMount(at: mountPoint, notIn: before) != nil {
                succeededBackend = backend ?? request.backend
                break
            }
            // Nothing appeared. Make sure a half-started ntfs-3g isn't left behind
            // before we try the next backend.
            reapProcesses(forDevice: devicePath, gracePeriod: 3)
        }

        guard let succeededBackend, let entry = MountTable.entry(atMountPoint: mountPoint) ?? waitForMount(at: mountPoint, notIn: before) else {
            removeMountPointIfEmpty(mountPoint)
            let detail = attempts.map { attempt in
                let label = attempt.0.map { "backend=\($0.rawValue)" } ?? "default backend"
                let diagnostic = attempt.1.combinedDiagnostic ?? "no output"
                return "[\(label)] exit \(attempt.1.exitCode): \(diagnostic)"
            }.joined(separator: "\n")
            return .failure(HelperFailure(kind: attempts.contains(where: { $0.1.succeeded }) ? .mountDidNotAppear : .ntfs3gFailed,
                                          message: "ntfs-3g could not mount \(displayName).",
                                          detail: detail.isEmpty ? nil : detail))
        }

        if entry.isReadOnly {
            log.error("Mount at \(mountPoint, privacy: .public) came up read-only.")
        }

        let pid = ntfs3gProcess(forDevice: devicePath)?.pid ?? 0
        let record = MountRecord(bsdName: request.bsdName,
                                 mountPoint: entry.mountPoint,
                                 backend: succeededBackend,
                                 pid: pid)
        stateStore.record(record)
        log.notice("Mounted \(request.bsdName, privacy: .public) at \(entry.mountPoint, privacy: .public)")

        return .mounted(MountResult(bsdName: request.bsdName,
                                    mountPoint: entry.mountPoint,
                                    backend: succeededBackend,
                                    pid: pid))
    }

    // MARK: - Unmount / eject

    func unmount(_ request: UnmountRequest, thenEject: Bool) -> HelperResponse {
        guard BSDName.isValid(request.bsdName), let devicePath = BSDName.devicePath(request.bsdName) else {
            return .failure(HelperFailure(kind: .invalidRequest,
                                          message: "“\(request.bsdName)” is not a valid disk identifier."))
        }

        // The FUSE mount is not associated with the device in the kernel mount table,
        // so find it the way it was actually created: from the ntfs-3g argument vector,
        // falling back to what we recorded when we mounted it.
        //
        // The two trusted sources are consulted first. A caller-supplied mount point is
        // only honoured if it agrees with one of them: this runs as root, and
        // `MountTable.isMountPoint` alone would happily accept "/" or
        // "/System/Volumes/Data". The helper unmounts what it mounted, nothing else.
        let discovered = ntfs3gMountPoint(forDevice: devicePath)
            ?? stateStore.record(forBSDName: request.bsdName)?.mountPoint
        let fuseMountPoint: String?
        if let requested = request.mountPoint {
            guard Self.isPlausibleMountPoint(requested) else {
                return .failure(HelperFailure(
                    kind: .invalidRequest,
                    message: "“\(requested)” is not a mount point this helper can unmount.",
                    detail: "Only volumes mounted under /Volumes by Cleat can be unmounted."))
            }
            guard discovered == nil || discovered == requested else {
                log.error("""
                Refusing to unmount \(requested, privacy: .public): \
                \(request.bsdName, privacy: .public) is mounted at \
                \(discovered ?? "nowhere", privacy: .public).
                """)
                return .failure(HelperFailure(
                    kind: .invalidRequest,
                    message: "That mount point does not belong to \(request.bsdName).",
                    detail: "Refusing to unmount a path this device is not mounted at."))
            }
            fuseMountPoint = requested
        } else {
            fuseMountPoint = discovered
        }

        if let fuseMountPoint, MountTable.isMountPoint(fuseMountPoint) {
            if let failure = unmountPath(fuseMountPoint, force: !request.refuseIfBusy) {
                return .failure(failure)
            }
            // Give the daemon a chance to notice and exit on its own.
            let leftover = reapProcesses(forDevice: devicePath, gracePeriod: 10)
            if !leftover.isEmpty {
                log.error("ntfs-3g still running after unmount: \(leftover.map(\.pid).description, privacy: .public)")
                return .failure(HelperFailure(
                    kind: .unmountFailed,
                    message: "The volume was unmounted but ntfs-3g is still running.",
                    detail: "Process ID(s): \(leftover.map { String($0.pid) }.joined(separator: ", ")). "
                          + "Nothing was force-killed. Close anything still using the drive and try again."))
            }
            removeMountPointIfEmpty(fuseMountPoint)
        }

        // Anything macOS itself mounted (its read-only driver, or another partition).
        if MountTable.entry(forDevice: request.bsdName) != nil {
            if let failure = unmountDevice(request.bsdName, force: !request.refuseIfBusy) {
                return .failure(failure)
            }
        }

        stateStore.remove(bsdName: request.bsdName)

        guard thenEject else { return .unmounted(bsdName: request.bsdName) }

        guard let whole = BSDName.wholeDisk(of: request.bsdName) else {
            return .failure(HelperFailure(kind: .invalidRequest,
                                          message: "Could not determine the physical disk for \(request.bsdName)."))
        }
        // Every volume on the device has to be unmounted before the hardware goes away.
        if let failure = unmountDevice(whole, whole: true, force: !request.refuseIfBusy) {
            return .failure(failure)
        }
        if let failure = ejectDisk(whole) {
            return .failure(failure)
        }
        return .unmounted(bsdName: request.bsdName)
    }

    // MARK: - Introspection

    func activeMounts() -> HelperResponse {
        let mountPoints = Set(MountTable.current().map(\.mountPoint))
        var results: [ActiveMount] = []
        for process in ProcessTable.processes(named: "ntfs-3g") {
            guard let (device, mountPoint) = NTFS3GInvocation.deviceAndMountPoint(from: process.arguments) else { continue }
            let bsdName = (device as NSString).lastPathComponent
            guard BSDName.isValid(bsdName), mountPoints.contains(mountPoint) else { continue }
            let backend = stateStore.record(forBSDName: bsdName)?.backend ?? .nfs
            results.append(ActiveMount(bsdName: bsdName,
                                       mountPoint: mountPoint,
                                       pid: process.pid,
                                       backend: backend))
        }
        stateStore.prune(keeping: Set(results.map(\.bsdName)))
        return .activeMounts(results)
    }

    // MARK: - ntfs-3g invocation

    private func backendAttemptOrder(preferred: FUSEBackend) -> [FUSEBackend?] {
        // `nil` means "don't pass a backend option at all", which is what an older
        // FUSE-T that predates the option needs.
        switch preferred {
        case .fskit: return [.fskit, .nfs, nil]
        case .nfs: return [.nfs, nil]
        }
    }

    private func childEnvironment() -> [String: String] {
        [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/var/root",
            "TMPDIR": "/private/tmp"
        ]
    }

    private func isExecutableNTFS3G(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("..") else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Whether a caller-supplied path is shaped like a mount point this helper owns.
    ///
    /// Deliberately strict: an absolute, traversal-free path strictly inside /Volumes.
    /// This is a root process acting on a path that arrived over XPC, so the check is
    /// on the shape of the path itself and never on what happens to be mounted there.
    static func isPlausibleMountPoint(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/"), path != "/Volumes", path != "/Volumes/" else { return false }
        guard !path.contains("\0") else { return false }
        let components = (path as NSString).pathComponents
        guard !components.contains(".."), !components.contains(".") else { return false }
        // "/Volumes/x" is ["/", "Volumes", "x"]; anything shallower is not a volume.
        return components.count >= 3 && path == (path as NSString).standardizingPath
    }

    // MARK: - Mount points

    private func makeMountPoint(named name: String, uid: uid_t, gid: gid_t) throws -> String {
        let fileManager = FileManager.default
        var candidate = "/Volumes/\(name)"
        var suffix = 1
        while true {
            if !fileManager.fileExists(atPath: candidate) { break }
            // Reuse an empty leftover directory; never touch a real mount or a
            // directory that has anything in it.
            if !MountTable.isMountPoint(candidate),
               let contents = try? fileManager.contentsOfDirectory(atPath: candidate),
               contents.isEmpty {
                break
            }
            suffix += 1
            candidate = "/Volumes/\(name) \(suffix)"
            if suffix > 50 {
                throw NSError(domain: "com.cleat.helper", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Too many leftover mount points named “\(name)”."
                ])
            }
        }
        if !fileManager.fileExists(atPath: candidate) {
            try fileManager.createDirectory(atPath: candidate,
                                            withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o755])
        }
        _ = chown(candidate, uid, gid)
        return candidate
    }

    private func removeMountPointIfEmpty(_ path: String) {
        guard path.hasPrefix("/Volumes/"), path != "/Volumes" else { return }
        guard !MountTable.isMountPoint(path) else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        guard contents.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func waitForMount(at path: String, notIn previous: Set<String>) -> MountTableEntry? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let table = MountTable.current()
            if let exact = table.first(where: { $0.mountPoint == path }) { return exact }
            // FSKit may place the volume at a path of its own choosing; accept a
            // single newly-appeared /Volumes mount as ours.
            let fresh = table.filter { $0.mountPoint.hasPrefix("/Volumes/") && !previous.contains($0.mountPoint) }
            if fresh.count == 1 { return fresh[0] }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    // MARK: - Unmount primitives

    /// Returns `nil` on success, or the failure to report.
    private func unmountPath(_ path: String, force: Bool) -> HelperFailure? {
        let flags = force ? MNT_FORCE : 0
        if Darwin.unmount(path, flags) == 0 { return nil }
        let code = errno
        if code == EINVAL || code == ENOENT { return nil } // already gone
        if code == EBUSY {
            return HelperFailure(kind: .volumeBusy,
                                 message: "\(( path as NSString).lastPathComponent) is in use and was not unmounted.",
                                 detail: "Close any apps or Terminal windows using the drive, then try again. "
                                       + "Nothing was force-unmounted.")
        }
        return HelperFailure(kind: .unmountFailed,
                             message: "Could not unmount \(path).",
                             detail: String(cString: strerror(code)))
    }

    private func unmountDevice(_ bsdName: String, whole: Bool = false, force: Bool) -> HelperFailure? {
        if let diskArbitration {
            do {
                try diskArbitration.unmount(bsdName: bsdName, whole: whole, force: force)
                return nil
            } catch let error as DAError {
                if error.isNotMounted { return nil }
                if error.isBusy {
                    return HelperFailure(kind: .volumeBusy,
                                         message: "\(bsdName) is in use and was not unmounted.",
                                         detail: error.localizedMessage
                                               + " Nothing was force-unmounted.")
                }
                log.error("DiskArbitration unmount failed: \(error.localizedMessage, privacy: .public)")
            } catch {
                log.error("DiskArbitration unmount threw: \(String(describing: error), privacy: .public)")
            }
        }
        // Fall back to diskutil, which knows how to talk to UserFS/FSKit modules.
        let arguments = whole ? ["unmountDisk", bsdName] : ["unmount", bsdName]
        guard let result = try? ProcessRunner.run("/usr/sbin/diskutil", arguments: arguments, timeout: 30) else {
            return HelperFailure(kind: .unmountFailed, message: "Could not run diskutil to unmount \(bsdName).")
        }
        if result.succeeded { return nil }
        let diagnostic = result.combinedDiagnostic ?? ""
        if diagnostic.localizedCaseInsensitiveContains("busy") || diagnostic.localizedCaseInsensitiveContains("in use") {
            return HelperFailure(kind: .volumeBusy,
                                 message: "\(bsdName) is in use and was not unmounted.",
                                 detail: diagnostic)
        }
        return HelperFailure(kind: .unmountFailed,
                             message: "Could not unmount \(bsdName).",
                             detail: diagnostic.isEmpty ? nil : diagnostic)
    }

    private func ejectDisk(_ bsdName: String) -> HelperFailure? {
        if let diskArbitration {
            do {
                try diskArbitration.eject(bsdName: bsdName)
                return nil
            } catch let error as DAError {
                log.error("DiskArbitration eject failed: \(error.localizedMessage, privacy: .public)")
                if error.isBusy {
                    return HelperFailure(kind: .volumeBusy,
                                         message: "The drive is still in use and was not ejected.",
                                         detail: error.localizedMessage)
                }
            } catch {}
        }
        guard let result = try? ProcessRunner.run("/usr/sbin/diskutil", arguments: ["eject", bsdName], timeout: 30) else {
            return HelperFailure(kind: .ejectFailed, message: "Could not run diskutil to eject \(bsdName).")
        }
        if result.succeeded { return nil }
        return HelperFailure(kind: .ejectFailed,
                             message: "Could not eject \(bsdName).",
                             detail: result.combinedDiagnostic)
    }

    // MARK: - ntfs-3g process bookkeeping

    private func ntfs3gProcess(forDevice devicePath: String) -> RunningProcess? {
        ProcessTable.processes(named: "ntfs-3g").first { process in
            NTFS3GInvocation.deviceAndMountPoint(from: process.arguments)?.device == devicePath
        }
    }

    private func ntfs3gMountPoint(forDevice devicePath: String) -> String? {
        ntfs3gProcess(forDevice: devicePath).flatMap { NTFS3GInvocation.deviceAndMountPoint(from: $0.arguments)?.mountPoint }
    }

    /// Waits for ntfs-3g processes bound to a device to exit. Never signals them —
    /// a FUSE daemon that outlives its mount is reported to the user, not killed
    /// out from under whatever still has the volume open.
    @discardableResult
    private func reapProcesses(forDevice devicePath: String, gracePeriod: TimeInterval) -> [RunningProcess] {
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            let remaining = ProcessTable.processes(named: "ntfs-3g").filter {
                NTFS3GInvocation.deviceAndMountPoint(from: $0.arguments)?.device == devicePath
            }
            if remaining.isEmpty { return [] }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ProcessTable.processes(named: "ntfs-3g").filter {
            NTFS3GInvocation.deviceAndMountPoint(from: $0.arguments)?.device == devicePath
        }
    }
}
