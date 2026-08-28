import Foundation

final class T: @unchecked Sendable { var p = 0; var f = 0 }
let t = T()
func ck(_ n: String, _ c: @autoclosure () -> Bool, _ d: String = "") {
    if c() { t.p += 1; print("  ✓ \(n)") } else { t.f += 1; print("  ✗ \(n)\(d.isEmpty ? "" : "  — \(d)")") }
}
func sec(_ s: String) { print("\n=== \(s) ===") }

let bsd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "disk23s1"
guard let bridge = DiskArbitrationBridge() else { print("no DA session"); exit(2) }

sec("DAError status decoding")
ck("0xC010 decodes as EBUSY", DAError(status: DAReturn(bitPattern: 0xC010)).isBusy)
ck("0xC010 posix == EBUSY", DAError(status: DAReturn(bitPattern: 0xC010)).posixErrorCode == EBUSY)
ck("kDAReturnBusy decodes as busy", DAError(status: DAReturn(kDAReturnBusy)).isBusy)
ck("0xC016 (EINVAL) is notMounted", DAError(status: DAReturn(bitPattern: 0xC016)).isNotMounted)
ck("kDAReturnNotMounted is notMounted", DAError(status: DAReturn(kDAReturnNotMounted)).isNotMounted)
ck("success is not busy", !DAError(status: 0).isBusy)
ck("unrelated error is not busy", !DAError(status: DAReturn(kDAReturnBadArgument)).isBusy)
ck("EBUSY message is human", DAError(status: DAReturn(bitPattern: 0xC010)).localizedMessage.lowercased().contains("busy"),
   DAError(status: DAReturn(bitPattern: 0xC010)).localizedMessage)

sec("Input validation")
for bad in ["../../etc", "/dev/disk1", "disk1;rm -rf /", "", "rdisk1", "disk1 s1"] {
    do { try bridge.unmount(bsdName: bad, timeout: 5); ck("rejected \(bad.isEmpty ? "<empty>" : bad)", false, "it did NOT throw") }
    catch { ck("rejected \(bad.isEmpty ? "<empty>" : bad)", true) }
}

sec("Description lookup")
if let d = bridge.description(ofBSDName: bsd) {
    ck("description returned", true)
    ck("volume kind is ntfs", (d["DAVolumeKind"] as? String)?.lowercased() == "ntfs", "\(d["DAVolumeKind"] ?? "nil")")
    ck("NTFS has no DAVolumeUUID (known gap)", d["DAVolumeUUID"] == nil,
       "UUID present: \(d["DAVolumeUUID"] ?? "nil")")
} else { ck("description returned", false) }
ck("bogus name yields nil description", bridge.description(ofBSDName: "../evil") == nil)

sec("BUSY DETECTION — the never-force-unmount guarantee")
let mp = "/Volumes/QA Test NTFS"
let handle = FileHandle(forReadingAtPath: "\(mp)/$MFT") ?? FileHandle(forReadingAtPath: mp)
// Hold the volume open with a real working directory + open fd.
let holder = Process()
holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
holder.arguments = ["120"]
holder.currentDirectoryURL = URL(fileURLWithPath: mp)
try? holder.run()
Thread.sleep(forTimeInterval: 0.5)

do {
    try bridge.unmount(bsdName: bsd, timeout: 15)
    ck("busy volume refused unmount", false, "IT UNMOUNTED — data-loss risk")
} catch let e as DAError {
    ck("busy volume refused unmount", true)
    ck("…and was classified as BUSY (not a generic error)", e.isBusy,
       "status=0x\(String(UInt32(bitPattern: Int32(e.status)), radix: 16)) msg=\(e.localizedMessage)")
    ck("…and was NOT misclassified as notMounted", !e.isNotMounted)
} catch { ck("busy volume refused unmount", false, "\(error)") }

holder.terminate(); try? handle?.close()
Thread.sleep(forTimeInterval: 1.5)

sec("Unmount succeeds once idle")
do { try bridge.unmount(bsdName: bsd, timeout: 20); ck("idle volume unmounted", true) }
catch { ck("idle volume unmounted", false, "\(error)") }
Thread.sleep(forTimeInterval: 1.0)
ck("really gone from mount table", !MountTable.current().contains { $0.mountedFrom == "/dev/\(bsd)" })

sec("Unmount is idempotent")
do { try bridge.unmount(bsdName: bsd, timeout: 15); ck("second unmount tolerated", true, "returned success") }
catch let e as DAError {
    ck("second unmount tolerated", e.isNotMounted,
       "status=0x\(String(UInt32(bitPattern: Int32(e.status)), radix: 16)) msg=\(e.localizedMessage)")
} catch { ck("second unmount tolerated", false, "\(error)") }

print("\n──────────────────────────────")
print("PASS \(t.p)   FAIL \(t.f)")
exit(t.f == 0 ? 0 : 1)
