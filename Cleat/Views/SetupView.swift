import SwiftUI
import ServiceManagement

/// The dependency walkthrough. Deliberately never runs Homebrew or `sudo` for you:
/// these commands install software system-wide, and that stays the user's decision.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    ForEach(model.report.checks) { check in
                        CheckCard(check: check)
                    }
                    helperControls
                    footnote
                }
                .padding(18)
            }
        }
        .task { await model.refreshDependencies() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.report.isReady ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                .font(.title)
                .foregroundStyle(model.report.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.report.isReady ? "Ready to mount" : "Set-up")
                    .font(.title3.weight(.semibold))
                Text(model.report.isReady
                     ? "Everything Cleat needs is installed."
                     : "Work through the items below. Nothing here needs a kernel extension, "
                     + "Reduced Security, or SIP changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await model.refreshDependencies() }
            } label: {
                if model.isCheckingDependencies {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Re-check")
                }
            }
            .disabled(model.isCheckingDependencies)
        }
        .padding(18)
    }

    private var intro: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("How this works")
                    .font(.callout.weight(.semibold))
                Text("""
                macOS can read NTFS but not write it. Cleat unmounts the read-only volume \
                macOS created and re-mounts the same device with ntfs-3g running on FUSE-T — a \
                userspace FUSE implementation that needs no kernel extension. On macOS 26 it uses \
                FUSE-T's FSKit backend; on macOS 15 it uses FUSE-T's NFSv4 loopback backend.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var helperControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Privileged helper")
                    .font(.callout.weight(.semibold))
                Text("""
                Opening a raw disk device requires root, so Cleat keeps that work in a small \
                helper daemon installed with SMAppService. macOS asks you to approve it once. \
                It is registered from inside this app's bundle — no system launchd files are touched.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Install Helper") { Task { await model.installHelper() } }
                        .disabled(model.helperStatus == .enabled)
                    Button("Remove Helper") { Task { await model.removeHelper() } }
                        .disabled(model.helperStatus != .enabled)
                    Spacer()
                    Text(model.helperStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var footnote: some View {
        Text("""
        Cleat never force-unmounts a volume that has open files, and never formats, erases, \
        or repartitions anything. If an eject fails because the drive is busy, close whatever is \
        using it and try again.
        """)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CheckCard: View {
    @Environment(AppModel.self) private var model
    let check: DependencyCheck
    @State private var didCopy = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                    Text(check.title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !check.fixCommands.isEmpty {
                    CommandBlock(commands: check.fixCommands, didCopy: $didCopy)
                }

                if let url = check.fixURL {
                    Button(check.fixButtonTitle ?? "Open") {
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var symbol: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .checking: return "clock"
        }
    }

    private var color: Color {
        switch check.status {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        case .checking: return .secondary
        }
    }
}

private struct CommandBlock: View {
    let commands: [String]
    @Binding var didCopy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commands.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))

            HStack {
                Button(didCopy ? "Copied" : "Copy Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        didCopy = false
                    }
                }
                Text("Run these yourself in Terminal — Cleat won't change your Homebrew install for you.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .controlSize(.small)
        }
    }
}
