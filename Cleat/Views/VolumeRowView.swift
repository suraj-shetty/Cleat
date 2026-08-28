import SwiftUI

struct VolumeRowView: View {
    @Environment(AppModel.self) private var model
    let volume: NTFSVolume

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 17))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if case .mountedReadWrite(let info) = volume.state, info.backend == .nfs {
                        Text("NFS")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .rect(cornerRadius: 3))
                            .help("Mounted through FUSE-T's NFS backend. It works, but it may not "
                                + "appear in the Finder sidebar — open it from /Volumes.")
                    }
                }
                Text(volume.statusSummary)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Text(volume.bsdName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if case .mountedReadWrite(let info) = volume.state, info.totalBytes > 0 {
                    CapacityBar(used: info.usedFraction)
                        .padding(.top, 2)
                }

                actions
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if volume.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if volume.isMountedReadWrite {
                Button("Open") { model.reveal(volume) }
                Button("Eject") { Task { await model.eject(volume) } }
            } else {
                Button("Mount Read/Write") { Task { await model.mountReadWrite(volume) } }
                    .disabled(!model.report.isReady)
                    .help(model.report.isReady
                          ? "Unmount the read-only macOS mount and re-mount with ntfs-3g"
                          : "Finish set-up first — open Setup from the bottom of this menu.")
                if volume.readOnlyMountPoint != nil {
                    Button("Open") { model.reveal(volume) }
                }
            }

            Spacer()

            Menu {
                Toggle("Always mount read/write",
                       isOn: Binding(get: { model.preferences.alwaysMountReadWrite(volume) },
                                     set: { _ in model.toggleAlwaysMount(volume) }))
                Divider()
                if volume.isMountedReadWrite {
                    Button("Unmount (don't eject)") { Task { await model.unmount(volume) } }
                }
                if let path = volume.mountPoint {
                    Button("Copy Mount Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private var iconName: String {
        switch volume.state {
        case .mountedReadWrite: return "externaldrive.fill.badge.checkmark"
        case .failed: return "externaldrive.badge.exclamationmark"
        case .working: return "externaldrive"
        case .idle: return volume.readOnlyMountPoint != nil ? "externaldrive.badge.minus" : "externaldrive"
        }
    }

    private var iconColor: Color {
        switch volume.state {
        case .mountedReadWrite: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var statusColor: Color {
        if case .failed = volume.state { return .red }
        return .secondary
    }
}

private extension NTFSVolume.MountedInfo {
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        let used = totalBytes >= freeBytes ? totalBytes - freeBytes : 0
        return min(1, Double(used) / Double(totalBytes))
    }
}

private struct CapacityBar: View {
    let used: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(used > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: max(2, geometry.size.width * used))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 220)
    }
}
