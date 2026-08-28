import Foundation
import ServiceManagement

/// Works out whether the FUSE-T + ntfs-3g stack is actually usable.
///
/// The failure this is really built to catch is the common one: ntfs-3g installed
/// from the Homebrew formula that depends on macFUSE, so the binary links against
/// `libfuse.2.dylib` and needs the kernel extension we refuse to require. That
/// install looks fine to `which ntfs-3g` and fails only at mount time, so the link
/// is inspected directly.
struct DependencyChecker: Sendable {

    private static let ntfs3gCandidates = [
        "/usr/local/bin/ntfs-3g",
        "/usr/local/sbin/ntfs-3g",
        "/opt/homebrew/bin/ntfs-3g",
        "/opt/homebrew/sbin/ntfs-3g"
    ]

    private static let fuseTLibrary = "/usr/local/lib/libfuse-t.dylib"
    private static let fuseTHeaders = "/usr/local/include/fuse"
    private static let fuseTSupport = "/Library/Application Support/fuse-t"

    func run() async -> DependencyReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.performChecks())
            }
        }
    }

    private static func performChecks() -> DependencyReport {
        var report = DependencyReport()
        report.lastRun = Date()

        // 1. FUSE-T itself.
        let fuseTInstalled = FileManager.default.fileExists(atPath: fuseTLibrary)
        report.checks.append(fuseTCheck(installed: fuseTInstalled))

        // 2. ntfs-3g, and crucially which FUSE it is linked against.
        let inspected = ntfs3gCandidates
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { (path: $0, linkage: linkage(of: $0)) }

        let usable = inspected.first { $0.linkage == .fuseT }
        report.usableNTFS3GPath = usable?.path
        report.checks.append(ntfs3gCheck(inspected: inspected))

        // 3. FSKit backend, on the systems that have it.
        if #available(macOS 26.0, *) {
            let enabled = fskitModuleEnabled()
            report.backend = enabled ? .fskit : .nfs
            report.checks.append(fskitCheck(enabled: enabled, fuseTInstalled: fuseTInstalled))
        } else {
            report.backend = .nfs
            report.checks.append(DependencyCheck(
                id: "fskit",
                title: "FSKit backend",
                status: .ok,
                detail: "Not applicable on macOS 15. FUSE-T's NFSv4 loopback backend will be used, "
                      + "which needs no kernel extension either."))
        }

        // 4. Full Disk Access.
        report.checks.append(fullDiskAccessCheck())

        // 5. Privileged helper.
        report.checks.append(helperCheck())

        // 6. Conflicting third-party NTFS drivers that could claim the disk first.
        if let conflict = conflictingDriverCheck() { report.checks.append(conflict) }

        return report
    }

    // MARK: - Individual checks

    private static func fuseTCheck(installed: Bool) -> DependencyCheck {
        guard installed else {
            return DependencyCheck(
                id: "fuse-t",
                title: "FUSE-T",
                status: .failed,
                detail: "FUSE-T is not installed. It provides userspace FUSE with no kernel extension "
                      + "and no Reduced Security changes.",
                fixCommands: ["brew install macos-fuse-t/homebrew-cask/fuse-t"],
                fixURL: URL(string: "https://github.com/macos-fuse-t/fuse-t/releases"),
                fixButtonTitle: "Open FUSE-T Releases")
        }
        var detail = "Installed at \(fuseTLibrary)."
        if let version = fuseTVersion() { detail = "Version \(version) installed." }
        if !FileManager.default.fileExists(atPath: fuseTHeaders) {
            detail += " Headers are missing from \(fuseTHeaders); you will need them only if you rebuild ntfs-3g."
        }
        return DependencyCheck(id: "fuse-t", title: "FUSE-T", status: .ok, detail: detail)
    }

    private enum Linkage: Equatable {
        case fuseT
        case macFUSE
        case unknown(String)
    }

    private static func linkage(of path: String) -> Linkage {
        guard let result = try? ProcessRunner.run("/usr/bin/otool",
                                                  arguments: ["-L", path],
                                                  timeout: 15),
              result.succeeded else {
            return .unknown("could not inspect the binary")
        }
        let output = result.standardOutput
        if output.contains("libfuse-t") { return .fuseT }
        if output.contains("libfuse.2.dylib") || output.lowercased().contains("macfuse")
            || output.contains("libosxfuse") {
            return .macFUSE
        }
        return .unknown("no FUSE library found in its link list")
    }

    private static func ntfs3gCheck(inspected: [(path: String, linkage: Linkage)]) -> DependencyCheck {
        let buildCommands = [
            "brew install automake autoconf libtool libgcrypt pkg-config gnutls",
            "git clone https://github.com/macos-fuse-t/ntfs-3g && cd ntfs-3g",
            "export CPPFLAGS=\"-I/usr/local/include/fuse\"",
            "export LDFLAGS=\"-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib\"",
            "./autogen.sh",
            "./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external --sbindir=/usr/local/bin --bindir=/usr/local/bin",
            "make -j\"$(sysctl -n hw.ncpu)\" && sudo make install"
        ]

        guard !inspected.isEmpty else {
            return DependencyCheck(
                id: "ntfs-3g",
                title: "ntfs-3g linked against FUSE-T",
                status: .failed,
                detail: "No ntfs-3g binary was found. It has to be built against FUSE-T — the "
                      + "ready-made Homebrew formula is built against macFUSE and will not work here.",
                fixCommands: buildCommands)
        }

        if let good = inspected.first(where: { $0.linkage == .fuseT }) {
            var detail = "\(good.path) is linked against FUSE-T."
            let bad = inspected.filter { $0.linkage != .fuseT }
            if !bad.isEmpty {
                detail += " Also found, and ignored: "
                    + bad.map { "\($0.path) (\(describe($0.linkage)))" }.joined(separator: ", ") + "."
            }
            return DependencyCheck(id: "ntfs-3g",
                                   title: "ntfs-3g linked against FUSE-T",
                                   status: .ok,
                                   detail: detail)
        }

        let listed = inspected.map { "\($0.path) — \(describe($0.linkage))" }.joined(separator: "\n")
        return DependencyCheck(
            id: "ntfs-3g",
            title: "ntfs-3g linked against FUSE-T",
            status: .failed,
            detail: "ntfs-3g is installed but not usable here:\n\(listed)\n\n"
                  + "A macFUSE-linked build needs the kernel extension this app deliberately avoids. "
                  + "Rebuild it against FUSE-T with the commands below.",
            fixCommands: buildCommands)
    }

    private static func describe(_ linkage: Linkage) -> String {
        switch linkage {
        case .fuseT: return "linked against FUSE-T"
        case .macFUSE: return "linked against macFUSE, which requires a kernel extension"
        case .unknown(let reason): return reason
        }
    }

    @available(macOS 26.0, *)
    private static func fskitModuleEnabled() -> Bool {
        // Deliberately NOT filtered with `-p FSModule`: FUSE-T's extension does not come
        // back from that protocol query on macOS 26.3, so filtering finds nothing even
        // when the module is installed and switched on.
        guard let result = try? ProcessRunner.run("/usr/bin/pluginkit",
                                                  arguments: ["-m", "-A", "-v"],
                                                  timeout: 15),
              result.succeeded else { return false }

        for line in result.standardOutput.split(separator: "\n") {
            // The identifier is `org.fuset.fskit-srv.module` — "fuset", not "fuse-t" —
            // and the bundle path contains "fuse-t.app". Match either.
            let lowered = line.lowercased()
            guard lowered.contains("fuset") || lowered.contains("fuse-t") else { continue }
            // Column 0 is the state flag: "+" explicitly enabled, "-" explicitly
            // disabled, space for the default. Most extensions, including this one after
            // being switched on in System Settings, carry a blank flag — so only an
            // explicit "-" means disabled. Requiring "+" here reported every working
            // install as broken.
            return line.first != "-"
        }
        return false
    }

    @available(macOS 26.0, *)
    private static func fskitCheck(enabled: Bool, fuseTInstalled: Bool) -> DependencyCheck {
        if enabled {
            return DependencyCheck(id: "fskit",
                                   title: "FSKit backend",
                                   status: .ok,
                                   detail: "FUSE-T's FSKit module is enabled. Volumes will mount through "
                                         + "FSKit, which integrates with Finder and Disk Utility properly.")
        }
        return DependencyCheck(
            id: "fskit",
            title: "FSKit backend",
            status: .warning,
            detail: fuseTInstalled
                ? "FUSE-T's FSKit module is not enabled. Mounting still works through the NFSv4 loopback "
                + "backend, but the volume may not appear in the Finder sidebar — open it from /Volumes "
                + "instead. To enable it, open fuse-t.app once, then turn on FUSE-T under File System "
                + "Extensions in System Settings."
                : "Install FUSE-T first, then enable its FSKit module in System Settings › General › "
                + "Login Items & Extensions › File System Extensions.",
            fixURL: URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences"),
            fixButtonTitle: "Open Extension Settings")
    }

    /// Whether this process can actually read a TCC-protected file.
    ///
    /// Uses `open(2)` rather than `FileManager.isReadableFile`, which is `access(2)`:
    /// the two can disagree under TCC, and `access` is the one that lies. Several paths
    /// are tried because a missing file is indistinguishable from a denied one, and a
    /// single missing probe would report "not granted" forever.
    private static func fullDiskAccessGranted() -> Bool {
        let probes = [
            ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath,
            "/Library/Application Support/com.apple.TCC/TCC.db",
            ("~/Library/Safari/Bookmarks.plist" as NSString).expandingTildeInPath
        ]
        for path in probes {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            // EPERM/EACCES is a real denial; anything else means this probe is unusable.
            if errno != EPERM && errno != EACCES { continue }
            return false
        }
        return false
    }

    private static func fullDiskAccessCheck() -> DependencyCheck {
        if fullDiskAccessGranted() {
            return DependencyCheck(id: "fda",
                                   title: "Full Disk Access",
                                   status: .ok,
                                   detail: "Granted. The app can see removable volumes and their contents.")
        }
        return DependencyCheck(
            id: "fda",
            title: "Full Disk Access",
            status: .warning,
            detail: "Not granted. Mounting works without it, but macOS may block the app from listing "
                  + "files on removable volumes, and FUSE-T's NFS backend can return “Operation not "
                  + "permitted”. Add Cleat under Privacy & Security › Full Disk Access.\n\n"
                  + "If you already switched it on and this is still red: macOS only applies the "
                  + "grant to a process when it launches, so quit Cleat and open it again. "
                  + "If it is still red after that, remove Cleat from the list with “−” and "
                  + "add it back — a grant is tied to the app’s code signature, and re-signing or "
                  + "replacing the app invalidates it.",
            fixURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            fixButtonTitle: "Open Full Disk Access")
    }

    private static func helperCheck() -> DependencyCheck {
        let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
        switch service.status {
        case .enabled:
            return DependencyCheck(id: "helper",
                                   title: "Privileged helper",
                                   status: .ok,
                                   detail: "Registered. Mounting a raw device needs root; everything "
                                         + "privileged happens in this small helper, not in the UI.")
        case .requiresApproval:
            return DependencyCheck(
                id: "helper",
                title: "Privileged helper",
                status: .failed,
                detail: "Waiting for your approval in System Settings › General › Login Items & Extensions.",
                fixURL: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
                fixButtonTitle: "Open Login Items")
        case .notRegistered, .notFound:
            return DependencyCheck(id: "helper",
                                   title: "Privileged helper",
                                   status: .failed,
                                   detail: "Not installed yet. Use “Install Helper” below; macOS will ask "
                                         + "you to approve it once.")
        @unknown default:
            return DependencyCheck(id: "helper",
                                   title: "Privileged helper",
                                   status: .failed,
                                   detail: "In an unrecognised state. Try removing and re-installing it.")
        }
    }

    /// A third-party NTFS FSKit module or filesystem bundle with a lower probe order
    /// than Apple's will claim the disk before anything else gets a chance. That is
    /// not fatal — the mount flow unmounts whatever claimed it first — but it is worth
    /// naming, because it is the usual reason a drive keeps coming back read-only.
    private static func conflictingDriverCheck() -> DependencyCheck? {
        let path = "/Library/Filesystems"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        let ntfsBundles = entries.filter {
            $0.lowercased().contains("ntfs") && $0.hasSuffix(".fs")
        }
        let macFUSEInstalled = entries.contains("macfuse.fs")
        guard !ntfsBundles.isEmpty || macFUSEInstalled else { return nil }

        var parts: [String] = []
        if !ntfsBundles.isEmpty {
            parts.append("Another NTFS filesystem bundle is installed (\(ntfsBundles.joined(separator: ", "))). "
                       + "It may mount your drive before Cleat does; the drive is unmounted from it "
                       + "automatically before being re-mounted read/write.")
        }
        if macFUSEInstalled {
            parts.append("macFUSE is installed. Cleat never uses it, but its Homebrew formula is what "
                       + "pulls in the wrong ntfs-3g build, so check the ntfs-3g row above.")
        }
        return DependencyCheck(id: "conflicts",
                               title: "Other NTFS drivers",
                               status: .warning,
                               detail: parts.joined(separator: "\n\n"))
    }

    private static func fuseTVersion() -> String? {
        let candidates = ["/Applications/fuse-t.app/Contents/Info.plist",
                          "\(fuseTSupport)/fuse-t.app/Contents/Info.plist"]
        for candidate in candidates {
            guard let data = FileManager.default.contents(atPath: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = plist["CFBundleShortVersionString"] as? String else { continue }
            return version
        }
        return nil
    }
}
