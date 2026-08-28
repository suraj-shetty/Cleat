import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Section {
                Toggle("Open Cleat at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { preferences.launchAtLogin = $0 }))
                Toggle("Ask before mounting remembered drives", isOn: $preferences.confirmBeforeAutoMount)
                    .help("When off, a drive you marked “always mount read/write” is mounted as soon "
                        + "as it is connected.")
            } header: {
                Text("General")
            }

            Section {
                if model.preferences.autoMountIdentities.isEmpty {
                    Text("No drives are set to mount read/write automatically.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.preferences.autoMountIdentities).sorted(), id: \.self) { identity in
                        HStack {
                            Text(displayName(for: identity))
                                .lineLimit(1)
                            Spacer()
                            Text(identity)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Forget") { model.preferences.forget(identity) }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Remembered Drives")
            } footer: {
                Text("Preferences follow the drive, not the device name macOS assigns it. Where macOS "
                   + "publishes a volume UUID that is used; NTFS volumes often have none, so the volume "
                   + "name and capacity identify them instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 340)
    }

    private func displayName(for identity: String) -> String {
        model.volumes.first { $0.identity == identity }?.name ?? "Not connected"
    }
}
