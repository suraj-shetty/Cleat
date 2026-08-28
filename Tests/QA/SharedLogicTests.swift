import Foundation

final class Tally: @unchecked Sendable { var pass = 0; var fail = 0 }
let tally = Tally()
func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
    if condition() { tally.pass += 1; print("  ✓ \(name)") }
    else { tally.fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
}
func section(_ s: String) { print("\n=== \(s) ===") }

// ---------------------------------------------------------------- BSDName
section("BSDName validation")
check("disk4 valid", BSDName.isValid("disk4"))
check("disk4s1 valid", BSDName.isValid("disk4s1"))
check("disk3s1s1 valid", BSDName.isValid("disk3s1s1"))
check("disk23s1 valid", BSDName.isValid("disk23s1"))
check("empty rejected", !BSDName.isValid(""))
check("traversal rejected", !BSDName.isValid("../../etc/passwd"))
check("absolute path rejected", !BSDName.isValid("/dev/disk4"))
check("semicolon rejected", !BSDName.isValid("disk4;rm -rf /"))
check("space rejected", !BSDName.isValid("disk4 s1"))
check("newline rejected", !BSDName.isValid("disk4\nfoo"))
check("null byte rejected", !BSDName.isValid("disk4\0"))
check("no digits rejected", !BSDName.isValid("disk"))
check("rdisk rejected", !BSDName.isValid("rdisk4"))
check("leading zero-ish ok", BSDName.isValid("disk0"))
check("devicePath", BSDName.devicePath("disk4s1") == "/dev/disk4s1")
check("devicePath nil on junk", BSDName.devicePath("../evil") == nil)
check("rawDevicePath", BSDName.rawDevicePath("disk4s1") == "/dev/rdisk4s1")
check("wholeDisk s1", BSDName.wholeDisk(of: "disk4s1") == "disk4")
check("wholeDisk nested", BSDName.wholeDisk(of: "disk3s1s1") == "disk3")
check("wholeDisk of whole", BSDName.wholeDisk(of: "disk4") == "disk4")

// ---------------------------------------------------------------- sanitizer
section("VolumeNameSanitizer / option injection")
let hostile = "Evil,backend=nfs,allow_other=1;rm -rf /\nfoo"
let safe = NTFS3GInvocation.optionSafeVolumeName(hostile)
check("no comma survives", !safe.contains(","), safe)
check("no equals survives", !safe.contains("="), safe)
check("no newline survives", !safe.contains("\n"), safe)
check("empty falls back", !NTFS3GInvocation.optionSafeVolumeName("").isEmpty)
check("null byte stripped", !NTFS3GInvocation.optionSafeVolumeName("a\0b").contains("\0"))

// ---------------------------------------------------------------- arguments
section("ntfs-3g argument construction")
let args = NTFS3GInvocation.arguments(devicePath: "/dev/disk23s1",
                                      mountPoint: "/Volumes/QA Test NTFS",
                                      volumeName: hostile,
                                      uid: 501, gid: 20, backend: .fskit)
check("argv[0] is device", args[0] == "/dev/disk23s1")
check("argv[1] is mountpoint", args[1] == "/Volumes/QA Test NTFS")
check("argv[2] is -o", args[2] == "-o")
let optionList = args[3]
check("exactly one backend option", optionList.components(separatedBy: "backend=").count == 2, optionList)
let optionCount = optionList.split(separator: ",").count
check("option count is 9", optionCount == 9, "got \(optionCount): \(optionList)")
check("uid present", optionList.contains("uid=501"))
// A ";" surviving in a volume label is FINE: nothing here ever passes a command to a
// shell (verified: no /bin/sh, system(), or popen() anywhere). What must not survive is
// "," or "=", which would inject a *mount option* into the -o list.
let opts = optionList.split(separator: ",").map(String.init)
let volnameOption = opts.first { $0.hasPrefix("volname=") }
check("volname option present", volnameOption != nil)
let volnameValue = volnameOption.map { String($0.dropFirst("volname=".count)) } ?? ""
check("volname value has no comma", !volnameValue.contains(","), volnameValue)
check("volname value has no equals", !volnameValue.contains("="), volnameValue)
check("hostile label injected no extra options", opts.count == 9, "\(opts.count): \(opts)")
check("allow_other not duplicated", opts.filter { $0.hasPrefix("allow_other") }.count == 1)
check("backend not overridden by the label",
      opts.filter { $0.hasPrefix("backend=") } == ["backend=fskit"], "\(opts)")

section("argv round-trip (mount lookup depends on this)")
if let rt = NTFS3GInvocation.deviceAndMountPoint(from: args) {
    check("device round-trips", rt.device == "/dev/disk23s1", rt.device)
    check("mountPoint round-trips", rt.mountPoint == "/Volumes/QA Test NTFS", rt.mountPoint)
} else { check("round-trip parsed", false, "returned nil") }
check("rejects non-/dev first positional",
      NTFS3GInvocation.deviceAndMountPoint(from: ["/etc/passwd", "/mnt"]) == nil)
check("rejects single positional",
      NTFS3GInvocation.deviceAndMountPoint(from: ["/dev/disk1"]) == nil)
check("skips -o value",
      NTFS3GInvocation.deviceAndMountPoint(from: ["-o","ro","/dev/disk1","/mnt"])?.mountPoint == "/mnt")

// ---------------------------------------------------------------- mount table
section("MountTable (live kernel state)")
let mounts = MountTable.current()
check("non-empty", !mounts.isEmpty, "\(mounts.count)")
check("root present", mounts.contains { $0.mountPoint == "/" })
if let root = mounts.first(where: { $0.mountPoint == "/" }) {
    check("root has a device", !root.mountedFrom.isEmpty, root.mountedFrom)
}

// ---------------------------------------------------------------- probe
section("NTFSProbe against the live test volume")
let testBSD = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "disk23s1"
do {
    let bs = try NTFSProbe.read(bsdName: testBSD)
    check("probed \(testBSD) as NTFS", true)
    check("sector size sane", bs.bytesPerSector == 512 || bs.bytesPerSector == 4096, "\(bs.bytesPerSector)")
    print("     serial: \(String(bs.volumeSerial, radix: 16))")
} catch {
    check("probed \(testBSD) as NTFS", false, "\(error)")
}
check("isNTFS agrees", NTFSProbe.isNTFS(bsdName: testBSD))
check("APFS system volume rejected", !NTFSProbe.isNTFS(bsdName: "disk3s5"))
check("bogus BSD name rejected", !NTFSProbe.isNTFS(bsdName: "../../etc/passwd"))
check("nonexistent device rejected", !NTFSProbe.isNTFS(bsdName: "disk99s99"))

// ---------------------------------------------------------------- backend
section("FUSEBackend")
check("fskit preferred on 26+", FUSEBackend.preferredForCurrentOS == .fskit
      || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26)

// ---------------------------------------------------------------- request timeouts
section("HelperRequest timeouts (the spinner fix)")
let mreq = HelperRequest.activeMounts
check("activeMounts bounded", mreq.timeout > 0 && mreq.timeout <= 60, "\(mreq.timeout)")


// ---------------------------------------------------------------- live argv
section("ProcessTable: argv read back from the kernel (regression: argv[0] dedup)")
let fake = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
if !fake.isEmpty {
    let hostileArgs = NTFS3GInvocation.arguments(devicePath: "/dev/disk23s1",
                                                 mountPoint: "/tmp/qa mount point",
                                                 volumeName: hostile,
                                                 uid: 501, gid: 20, backend: .fskit)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: fake)
    proc.arguments = hostileArgs
    try? proc.run()
    Thread.sleep(forTimeInterval: 1.0)
    let pids = ProcessTable.processes(named: "ntfs-3g")
    check("live ntfs-3g found in process table",
          pids.contains { $0.pid == proc.processIdentifier },
          "pids=\(pids.map(\.pid)) want=\(proc.processIdentifier)")
    // The helper never calls arguments(of:) directly — it goes through processes(named:),
    // which drops the executable path. Test the path that actually ships.
    if let running = pids.first(where: { $0.pid == proc.processIdentifier }) {
        let argv = running.arguments
        check("argv count matches what we passed", argv.count == hostileArgs.count,
              "got \(argv.count) want \(hostileArgs.count): \(argv)")
        check("argv[0] is the device, not the exe path", argv.first == "/dev/disk23s1", argv.first ?? "nil")
        check("executablePath reported separately",
              (running.executablePath as NSString).lastPathComponent == "ntfs-3g", running.executablePath)
        check("option list arrived as ONE argv element",
              argv.filter { $0.contains("uid=501") }.count == 1, "\(argv)")
        if let rt = NTFS3GInvocation.deviceAndMountPoint(from: argv) {
            check("device recovered from live argv", rt.device == "/dev/disk23s1", rt.device)
            check("mountPoint with a space recovered", rt.mountPoint == "/tmp/qa mount point", rt.mountPoint)
        } else { check("live argv round-trip", false, "nil") }
        // Low-level contract: arguments(of:) keeps the exe path at index 0 by design.
        if let raw = ProcessTable.arguments(of: proc.processIdentifier) {
            check("arguments(of:) contract: exe path at index 0",
                  (raw.first.map { ($0 as NSString).lastPathComponent } ?? "") == "ntfs-3g", raw.first ?? "nil")
            check("arguments(of:) drops the argv[0] duplicate", raw.count == hostileArgs.count + 1,
                  "got \(raw.count) want \(hostileArgs.count + 1)")
        } else { check("arguments(of:) readable", false) }
    } else { check("running process located", false) }
    proc.terminate()
} else { print("  (skipped: no fake binary path given)") }

// ---------------------------------------------------------------- ProcessRunner
section("ProcessRunner safety")
check("relative path rejected", (try? ProcessRunner.run("echo", arguments: ["hi"], timeout: 5)) == nil)
check("nonexistent absolute path rejected",
      (try? ProcessRunner.run("/usr/bin/definitely-not-here", arguments: [], timeout: 5)) == nil)
if let r = try? ProcessRunner.run("/bin/echo", arguments: ["a;b", "c,d", "$(whoami)"], timeout: 10) {
    check("args passed literally, no shell expansion",
          r.standardOutput.contains("$(whoami)") && !r.standardOutput.contains(NSUserName()),
          r.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
} else { check("echo ran", false) }
let t0 = Date()
let slow = try? ProcessRunner.run("/bin/sleep", arguments: ["30"], timeout: 2)
let elapsed = Date().timeIntervalSince(t0)
check("timeout actually fires", elapsed < 8, "took \(String(format: "%.1f", elapsed))s")
check("timed-out run does not report success", slow?.succeeded != true)

print("\n──────────────────────────────")
print("PASS \(tally.pass)   FAIL \(tally.fail)")
exit(tally.fail == 0 ? 0 : 1)
