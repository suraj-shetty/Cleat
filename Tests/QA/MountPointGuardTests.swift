import Foundation

final class T: @unchecked Sendable { var p = 0; var f = 0 }
let t = T()
func ck(_ n: String, _ c: @autoclosure () -> Bool, _ d: String = "") {
    if c() { t.p += 1; print("  ✓ \(n)") } else { t.f += 1; print("  ✗ \(n)\(d.isEmpty ? "" : "  — \(d)")") }
}
func sec(_ s: String) { print("\n=== \(s) ===") }

sec("Mount-point guard (root unmounts only what it owns)")
let allowed = ["/Volumes/My Passport", "/Volumes/QA Test NTFS", "/Volumes/a"]
for p in allowed { ck("allows \(p)", MountEngine.isPlausibleMountPoint(p)) }
let denied = ["/", "/System/Volumes/Data", "/Volumes", "/Volumes/", "/etc",
              "/Volumes/../etc", "/Volumes/./x", "/Volumes/x/../../etc",
              "", "Volumes/x", "/private/tmp/x", "/Users/surajshetty",
              "/Volumes/x\0/y", "//Volumes/x"]
for p in denied {
    ck("denies \(p.isEmpty ? "<empty>" : p.replacingOccurrences(of: "\0", with: "\\0"))",
       !MountEngine.isPlausibleMountPoint(p))
}

sec("Mount-point naming from hostile volume labels (root creates + chowns these)")
let labels = ["../../etc", "/etc/passwd", "..", ".", "...", "", "   ",
              "a/b/c", "x\\y", "con:", "\u{0}evil", "-rf", ".hidden",
              String(repeating: "A", count: 400)]
for raw in labels {
    let name = VolumeNameSanitizer.sanitize(raw)
    let path = "/Volumes/\(name)"
    let shown = raw.replacingOccurrences(of: "\0", with: "\\0")
    ck("label \"\(shown.prefix(20))\" -> safe path", MountEngine.isPlausibleMountPoint(path),
       "became \(path)")
    ck("   …stays directly under /Volumes",
       (path as NSString).deletingLastPathComponent == "/Volumes", path)
}
ck("length is bounded", VolumeNameSanitizer.sanitize(String(repeating: "A", count: 400)).count <= 60)
ck("empty label falls back", VolumeNameSanitizer.sanitize("") == "NTFS Volume")

print("\n──────────────────────────────")
print("PASS \(t.p)   FAIL \(t.f)")
exit(t.f == 0 ? 0 : 1)
