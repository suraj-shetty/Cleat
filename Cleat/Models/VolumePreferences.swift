import Foundation
import Observation
import ServiceManagement

/// Per-volume and global settings.
///
/// The "always mount read/write" flag is keyed by `NTFSVolume.identity` — the
/// volume UUID where macOS provides one, and a volume-name plus media-size pair
/// where it does not — rather than by BSD name, because BSD names are reassigned
/// on every reconnect.
@Observable
@MainActor
final class VolumePreferences {
    private let defaults: UserDefaults
    private enum Key {
        static let autoMountUUIDs = "autoMountVolumeUUIDs"
        static let nicknames = "volumeNicknames"
        static let confirmBeforeAutoMount = "confirmBeforeAutoMount"
        static let hasCompletedSetup = "hasCompletedSetup"
    }

    /// Stored under the legacy key name so existing preferences keep working.
    private(set) var autoMountIdentities: Set<String>
    var confirmBeforeAutoMount: Bool {
        didSet { defaults.set(confirmBeforeAutoMount, forKey: Key.confirmBeforeAutoMount) }
    }
    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoMountIdentities = Set(defaults.stringArray(forKey: Key.autoMountUUIDs) ?? [])
        confirmBeforeAutoMount = defaults.bool(forKey: Key.confirmBeforeAutoMount)
        hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
    }

    func alwaysMountReadWrite(_ volume: NTFSVolume) -> Bool {
        autoMountIdentities.contains(volume.identity)
    }

    func setAlwaysMountReadWrite(_ enabled: Bool, for volume: NTFSVolume) {
        if enabled {
            autoMountIdentities.insert(volume.identity)
        } else {
            autoMountIdentities.remove(volume.identity)
        }
        defaults.set(Array(autoMountIdentities), forKey: Key.autoMountUUIDs)
    }

    func forget(_ identity: String) {
        autoMountIdentities.remove(identity)
        defaults.set(Array(autoMountIdentities), forKey: Key.autoMountUUIDs)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Cleat: could not change launch-at-login: \(error.localizedDescription)")
            }
        }
    }
}
