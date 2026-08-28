import Foundation
import Darwin

/// Reads the first sector of a device and decides whether it is really NTFS.
///
/// The helper refuses to hand any device to ntfs-3g that does not pass this check.
/// It is a read of 4096 bytes and nothing else — no write, no repair, no probe that
/// could alter the volume — and it is the last line of defence against pointing a
/// filesystem driver at, say, an APFS container because a description lookup lied.
public enum NTFSProbe {
    public struct BootSector: Sendable {
        public var oemID: String
        public var bytesPerSector: UInt16
        public var volumeSerial: UInt64
    }

    public enum ProbeError: Error, Sendable {
        case invalidDevice
        case cannotOpen(Int32)
        case shortRead
        case notNTFS(oemID: String)
    }

    public static func read(bsdName: String) throws -> BootSector {
        guard let rawPath = BSDName.rawDevicePath(bsdName) else {
            throw ProbeError.invalidDevice
        }
        let fd = open(rawPath, O_RDONLY)
        guard fd >= 0 else { throw ProbeError.cannotOpen(errno) }
        defer { close(fd) }

        // Raw character devices demand sector-aligned reads; 4096 satisfies both
        // 512-byte and 4K-native media.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
        guard bytesRead >= 512 else { throw ProbeError.shortRead }

        let oem = String(decoding: buffer[3..<11], as: UTF8.self)
        guard oem == "NTFS    " else { throw ProbeError.notNTFS(oemID: oem) }

        let bytesPerSector = UInt16(buffer[11]) | (UInt16(buffer[12]) << 8)
        var serial: UInt64 = 0
        for offset in (0x48..<0x50).reversed() {
            serial = (serial << 8) | UInt64(buffer[offset])
        }
        return BootSector(oemID: oem, bytesPerSector: bytesPerSector, volumeSerial: serial)
    }

    public static func isNTFS(bsdName: String) -> Bool {
        (try? read(bsdName: bsdName)) != nil
    }
}
