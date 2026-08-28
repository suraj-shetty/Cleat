import Foundation
import Observation
import AppKit
import ServiceManagement
import os

/// The single place that decides what the menu shows and what happens when you
/// click something. Everything here is main-actor isolated; the privileged work
/// happens in the helper and the disk watching happens on its own queue.
@Observable
@MainActor
final class AppModel {
    private let log = Logger(subsystem: "com.cleat.app", category: "AppModel")

    private(set) var volumes: [NTFSVolume] = []
    private(set) var report = DependencyReport()
    private(set) var isCheckingDependencies = false
    /// Last thing that went wrong, shown as a banner until dismissed.
    var lastError: PresentableError?

    let preferences = VolumePreferences()

    private let helper = HelperClient()
    private var monitor: DiskMonitor?
    private let checker = DependencyChecker()
    /// Volume identities auto-mounted this session, so a description-changed storm
    /// cannot trigger the same mount repeatedly.
    private var autoMountAttempted: Set<String> = []

    struct PresentableError: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String?
    }

    // MARK: - Lifecycle

    /// Idempotent on purpose.
    ///
    /// This is driven by the menu content's `.task`, which SwiftUI runs every time the
    /// menu bar window appears. Building a second `DiskMonitor` here would register a
    /// second set of DiskArbitration callbacks and drop the first without stopping it,
    /// so every menu open would add another watcher — and every watcher re-applies the
    /// volume list, which is what made the list flicker more the longer the app ran.
    func start() {
        guard monitor == nil else { return }
        monitor = DiskMonitor { [weak self] volumes in
            self?.apply(hardware: volumes)
        }
        monitor?.start()
        Task { await refreshDependencies() }
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }

    func refreshVolumes() {
        monitor?.refresh()
    }

    // MARK: - Dependencies

    func refreshDependencies() async {
        isCheckingDependencies = true
        let fresh = await checker.run()
        report = fresh
        isCheckingDependencies = false
        await reconcileWithHelper()
    }

    func installHelper() async {
        do {
            try await helper.install()
        } catch let error as HelperClient.ClientError {
            if case .awaitingApproval = error {
                lastError = PresentableError(
                    title: "Approve Cleat in System Settings",
                    detail: "macOS needs you to allow the helper under Login Items & Extensions. "
                          + "The check below will turn green once you do.")
                openLoginItemsSettings()
            } else {
                lastError = PresentableError(title: "Helper installation failed",
                                             detail: error.errorDescription)
            }
        } catch {
            lastError = PresentableError(title: "Helper installation failed",
                                         detail: error.localizedDescription)
        }
        await refreshDependencies()
    }

    func removeHelper() async {
        do {
            try await helper.uninstall()
        } catch {
            lastError = PresentableError(title: "Could not remove the helper",
                                         detail: error.localizedDescription)
        }
        await refreshDependencies()
    }

    // MARK: - Mount actions

    func mountReadWrite(_ volume: NTFSVolume) async {
        guard let ntfs3gPath = report.usableNTFS3GPath else {
            lastError = PresentableError(
                title: "Set-up isn't finished",
                detail: "No ntfs-3g linked against FUSE-T was found. Open Setup for the exact steps.")
            return
        }
        setState(.working("Mounting…"), for: volume.bsdName)

        let request = MountRequest(bsdName: volume.bsdName,
                                   volumeName: volume.name,
                                   ownerUID: getuid(),
                                   ownerGID: getgid(),
                                   backend: report.backend,
                                   ntfs3gPath: ntfs3gPath,
                                   refuseIfBusy: true)
        do {
            let response = try await helper.send(.mountReadWrite(request))
            guard case .mounted(let result) = response else {
                setState(.failed("Unexpected response from the helper."), for: volume.bsdName)
                return
            }
            let entry = MountTable.entry(atMountPoint: result.mountPoint)
            setState(.mountedReadWrite(NTFSVolume.MountedInfo(
                mountPoint: result.mountPoint,
                backend: result.backend,
                pid: result.pid,
                totalBytes: entry?.totalBytes ?? volume.mediaSize,
                freeBytes: entry?.freeBytes ?? 0)), for: volume.bsdName)
            if result.backend == .nfs {
                log.notice("Mounted via the NFS backend; the volume may not appear in the Finder sidebar.")
            }
        } catch {
            handleMountFailure(error, volume: volume)
        }
        refreshVolumes()
    }

    func unmount(_ volume: NTFSVolume) async {
        await unmount(volume, eject: false)
    }

    func eject(_ volume: NTFSVolume) async {
        await unmount(volume, eject: true)
    }

    private func unmount(_ volume: NTFSVolume, eject: Bool) async {
        setState(.working(eject ? "Ejecting…" : "Unmounting…"), for: volume.bsdName)
        let request = UnmountRequest(bsdName: volume.bsdName,
                                     mountPoint: volume.isMountedReadWrite ? volume.mountPoint : nil,
                                     refuseIfBusy: true)
        do {
            _ = try await helper.send(eject ? .eject(request) : .unmount(request))
            autoMountAttempted.remove(volume.identity)
            setState(.idle, for: volume.bsdName)
        } catch let error as HelperClient.ClientError {
            if case .helper(let failure) = error, failure.kind == .volumeBusy {
                setState(.idle, for: volume.bsdName)
                lastError = PresentableError(
                    title: eject ? "“\(volume.name)” is still in use" : "“\(volume.name)” is busy",
                    detail: (failure.detail ?? failure.message)
                          + "\n\nNothing was forced. Quit whatever is using the drive and try again.")
            } else {
                setState(.idle, for: volume.bsdName)
                lastError = PresentableError(title: "Could not \(eject ? "eject" : "unmount") “\(volume.name)”",
                                             detail: error.errorDescription)
            }
        } catch {
            setState(.idle, for: volume.bsdName)
            lastError = PresentableError(title: "Could not \(eject ? "eject" : "unmount") “\(volume.name)”",
                                         detail: error.localizedDescription)
        }
        refreshVolumes()
    }

    func reveal(_ volume: NTFSVolume) {
        guard let path = volume.mountPoint else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func toggleAlwaysMount(_ volume: NTFSVolume) {
        let newValue = !preferences.alwaysMountReadWrite(volume)
        preferences.setAlwaysMountReadWrite(newValue, for: volume)
        if !newValue { autoMountAttempted.remove(volume.identity) }
    }

    // MARK: - Reconciliation

    /// Folds the hardware picture from DiskArbitration together with the helper's
    /// view of which devices actually have a live ntfs-3g mount.
    /// Folds a fresh hardware scan into the list without losing what we know.
    ///
    /// `DiskMonitor` reports hardware only — it cannot see a FUSE mount, so every volume
    /// it returns arrives as `.idle`. Overwriting state wholesale therefore knocked every
    /// mounted volume back to "not mounted" until the helper round-trip finished a moment
    /// later, and the row visibly flipped Eject → Mount → Eject on every refresh.
    /// Carrying the previous state over keeps the row stable; `reconcileWithHelper` is
    /// the only thing allowed to decide a volume is no longer mounted.
    private func apply(hardware: [NTFSVolume]) {
        var merged = hardware
        for index in merged.indices {
            guard let existing = volumes.first(where: { $0.bsdName == merged[index].bsdName }) else {
                continue
            }
            merged[index].state = existing.state
        }
        // Assigning an identical array still notifies observers; skip it so an idle
        // refresh cannot cause a re-render at all.
        if merged != volumes {
            volumes = merged
        }
        Task { await reconcileWithHelper() }
    }

    private func reconcileWithHelper() async {
        guard helper.status == .enabled else { return }
        guard case .activeMounts(let active)? = try? await helper.send(.activeMounts) else { return }
        let byBSD = Dictionary(uniqueKeysWithValues: active.map { ($0.bsdName, $0) })

        for index in volumes.indices {
            if volumes[index].isBusy { continue }
            if let mount = byBSD[volumes[index].bsdName] {
                let entry = MountTable.entry(atMountPoint: mount.mountPoint)
                volumes[index].state = .mountedReadWrite(NTFSVolume.MountedInfo(
                    mountPoint: mount.mountPoint,
                    backend: mount.backend,
                    pid: mount.pid,
                    totalBytes: entry?.totalBytes ?? volumes[index].mediaSize,
                    freeBytes: entry?.freeBytes ?? 0))
            } else if volumes[index].isMountedReadWrite {
                volumes[index].state = .idle
            }
        }

        await performAutoMounts()
    }

    private func performAutoMounts() async {
        guard report.isReady else { return }
        for volume in volumes {
            let identity = volume.identity
            guard preferences.alwaysMountReadWrite(volume),
                  !preferences.confirmBeforeAutoMount,
                  !volume.isMountedReadWrite,
                  !volume.isBusy,
                  !autoMountAttempted.contains(identity) else { continue }
            autoMountAttempted.insert(identity)
            await mountReadWrite(volume)
        }
    }

    // MARK: - Helper status

    var helperStatus: SMAppService.Status { helper.status }

    var helperStatusDescription: String {
        switch helperStatus {
        case .enabled: return "Installed and running on demand."
        case .requiresApproval: return "Waiting for approval in System Settings."
        case .notRegistered: return "Not installed."
        case .notFound: return "Missing from the app bundle."
        @unknown default: return "Unknown state."
        }
    }

    // MARK: - Helpers

    private func setState(_ state: NTFSVolume.State, for bsdName: String) {
        guard let index = volumes.firstIndex(where: { $0.bsdName == bsdName }) else { return }
        volumes[index].state = state
    }

    private func handleMountFailure(_ error: Error, volume: NTFSVolume) {
        guard let clientError = error as? HelperClient.ClientError else {
            setState(.failed("Mount failed."), for: volume.bsdName)
            lastError = PresentableError(title: "Could not mount “\(volume.name)”",
                                         detail: error.localizedDescription)
            return
        }
        switch clientError {
        case .helper(let failure):
            setState(.failed(shortMessage(for: failure)), for: volume.bsdName)
            lastError = PresentableError(title: "Could not mount “\(volume.name)”",
                                         detail: [failure.message, failure.detail]
                                            .compactMap { $0 }
                                            .joined(separator: "\n\n"))
        case .notRegistered, .awaitingApproval:
            setState(.idle, for: volume.bsdName)
            lastError = PresentableError(title: "The privileged helper isn't ready",
                                         detail: clientError.errorDescription)
        default:
            setState(.failed("Mount failed."), for: volume.bsdName)
            lastError = PresentableError(title: "Could not mount “\(volume.name)”",
                                         detail: clientError.errorDescription)
        }
    }

    private func shortMessage(for failure: HelperFailure) -> String {
        switch failure.kind {
        case .volumeBusy: return "In use — not unmounted"
        case .notAnNTFSVolume: return "Not an NTFS volume"
        case .ntfs3gMissing: return "ntfs-3g missing"
        case .ntfs3gFailed, .mountDidNotAppear: return "ntfs-3g could not mount it"
        case .deviceNotFound: return "Drive disconnected"
        default: return "Mount failed"
        }
    }

    func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
