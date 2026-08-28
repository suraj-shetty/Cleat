import Foundation
import DiskArbitration
import os

/// Watches DiskArbitration for NTFS volumes appearing, disappearing, or changing.
///
/// Note that a volume mounted by *this* app through ntfs-3g/FUSE-T does not show up
/// here as mounted: the FUSE mount is not associated with the block device in the
/// kernel, so DiskArbitration keeps reporting the device as unmounted. The mounted
/// state is reconciled from the helper instead; this type only reports hardware.
final class DiskMonitor: @unchecked Sendable {
    private let log = Logger(subsystem: "com.cleat.app", category: "DiskMonitor")
    private let queue = DispatchQueue(label: "com.cleat.app.diskmonitor", qos: .userInitiated)
    private var session: DASession?

    /// Called on the main actor whenever the set of NTFS volumes may have changed.
    private let onChange: @MainActor @Sendable ([NTFSVolume]) -> Void

    /// The retained `self` handed to DiskArbitration as callback context.
    ///
    /// This MUST be a retained reference. DiskArbitration stores the raw pointer and
    /// keeps calling back until the callbacks are explicitly unregistered, so an
    /// unretained context turns "the owner released us" into a use-after-free on the
    /// next disk event rather than a clean no-op.
    private var context: UnsafeMutableRawPointer?

    // Held as stored properties because unregistering requires the *same* function
    // pointer that was registered; a fresh closure literal would not match.
    private static let diskAppeared: DADiskAppearedCallback = { _, context in
        DiskMonitor.fromContext(context)?.scheduleRefresh()
    }
    private static let diskDisappeared: DADiskDisappearedCallback = { _, context in
        DiskMonitor.fromContext(context)?.scheduleRefresh()
    }
    private static let diskDescriptionChanged: DADiskDescriptionChangedCallback = { _, _, context in
        DiskMonitor.fromContext(context)?.scheduleRefresh()
    }

    init(onChange: @escaping @MainActor @Sendable ([NTFSVolume]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.session == nil else { return }
            guard let session = DASessionCreate(kCFAllocatorDefault) else {
                self.log.error("Could not create a DiskArbitration session.")
                return
            }
            self.session = session
            let context = Unmanaged.passRetained(self).toOpaque()
            self.context = context

            DARegisterDiskAppearedCallback(session, nil, Self.diskAppeared, context)
            DARegisterDiskDisappearedCallback(session, nil, Self.diskDisappeared, context)
            DARegisterDiskDescriptionChangedCallback(session, nil, nil, Self.diskDescriptionChanged, context)

            DASessionSetDispatchQueue(session, self.queue)
            self.refresh()
        }
    }

    /// Tears the session down and releases the retained context.
    ///
    /// Ordering matters: detach the dispatch queue first so no new callback can be
    /// delivered, then unregister, and only then release. Releasing while a callback
    /// is still registered is the exact use-after-free this is written to avoid.
    func stop() {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            DASessionSetDispatchQueue(session, nil)
            if let context = self.context {
                DAUnregisterCallback(session, unsafeBitCast(Self.diskAppeared, to: UnsafeMutableRawPointer.self), context)
                DAUnregisterCallback(session, unsafeBitCast(Self.diskDisappeared, to: UnsafeMutableRawPointer.self), context)
                DAUnregisterCallback(session, unsafeBitCast(Self.diskDescriptionChanged, to: UnsafeMutableRawPointer.self), context)
                self.context = nil
                Unmanaged<DiskMonitor>.fromOpaque(context).release()
            }
            self.session = nil
        }
    }

    /// Re-reads the whole disk list. Cheap enough (a handful of IOKit lookups) that
    /// coalescing every notification into a full rescan is simpler and less racy
    /// than tracking individual disks.
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let volumes = Self.currentNTFSVolumes()
            let callback = self.onChange
            Task { @MainActor in callback(volumes) }
        }
    }

    private func scheduleRefresh() {
        // DiskArbitration fires several callbacks per plug-in event; let them settle.
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    private static func fromContext(_ context: UnsafeMutableRawPointer?) -> DiskMonitor? {
        guard let context else { return nil }
        return Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
    }

    // MARK: - Enumeration

    static func currentNTFSVolumes() -> [NTFSVolume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let mounts = MountTable.current()

        var volumes: [NTFSVolume] = []
        for bsdName in allLeafBSDNames() {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
                  let description = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            guard isNTFS(description) else { continue }

            let mediaSize = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
            let name = (description[kDADiskDescriptionVolumeNameKey as String] as? String)
                ?? (description[kDADiskDescriptionMediaNameKey as String] as? String)
                ?? bsdName
            var uuidString: String?
            if let value = description[kDADiskDescriptionVolumeUUIDKey as String] {
                let uuid = value as! CFUUID
                uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
            }
            let devicePath = "/dev/\(bsdName)"
            let readOnlyMountPoint = mounts.first { $0.mountedFrom == devicePath }?.mountPoint

            volumes.append(NTFSVolume(
                bsdName: bsdName,
                volumeUUID: uuidString,
                name: name,
                mediaSize: mediaSize,
                isRemovable: (description[kDADiskDescriptionMediaRemovableKey as String] as? NSNumber)?.boolValue ?? false,
                isEjectable: (description[kDADiskDescriptionMediaEjectableKey as String] as? NSNumber)?.boolValue ?? false,
                readOnlyMountPoint: readOnlyMountPoint))
        }
        return volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// True when DiskArbitration has probed this media as NTFS, or when it is an
    /// unprobed Microsoft basic-data partition that plausibly is. The helper does a
    /// boot-sector check before writing anything, so a false positive here only ever
    /// costs a menu entry, never a wrong mount.
    private static func isNTFS(_ description: [String: Any]) -> Bool {
        guard (description[kDADiskDescriptionMediaLeafKey as String] as? NSNumber)?.boolValue ?? false else {
            return false
        }
        if let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String {
            return kind.caseInsensitiveCompare("ntfs") == .orderedSame
        }
        guard let content = description[kDADiskDescriptionMediaContentKey as String] as? String else {
            return false
        }
        // GPT "Microsoft basic data" and the MBR NTFS/exFAT type respectively.
        return content == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" || content == "Windows_NTFS"
    }

    private static func allLeafBSDNames() -> [String] {
        guard let result = try? ProcessRunner.run("/usr/sbin/diskutil",
                                                  arguments: ["list", "-plist"],
                                                  timeout: 15),
              result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }
        var names: [String] = []
        for disk in all {
            if let partitions = disk["Partitions"] as? [[String: Any]] {
                names.append(contentsOf: partitions.compactMap { $0["DeviceIdentifier"] as? String })
            }
            if let volumes = disk["APFSVolumes"] as? [[String: Any]] {
                names.append(contentsOf: volumes.compactMap { $0["DeviceIdentifier"] as? String })
            }
            if (disk["Partitions"] as? [[String: Any]])?.isEmpty ?? true,
               let identifier = disk["DeviceIdentifier"] as? String {
                names.append(identifier)   // partitionless "superfloppy" media
            }
        }
        return names.filter { BSDName.isValid($0) }
    }
}
