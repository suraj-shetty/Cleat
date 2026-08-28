import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let error = model.lastError {
                ErrorBanner(error: error) { model.lastError = nil }
                Divider()
            }

            if !model.report.isReady && model.report.lastRun != .distantPast {
                setupPrompt
                Divider()
            }

            if model.volumes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.volumes) { volume in
                            VolumeRowView(volume: volume)
                            if volume.id != model.volumes.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
            footer
        }
        .frame(width: 380)
        .task { model.start() }
    }

    private var header: some View {
        HStack {
            Text("Cleat")
                .font(.headline)
            Spacer()
            Button {
                model.refreshVolumes()
                Task { await model.refreshDependencies() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-scan drives and re-check dependencies")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var setupPrompt: some View {
        Button {
            openWindow(id: WindowID.setup)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set-up isn't finished")
                        .font(.callout.weight(.medium))
                    Text(blockingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var blockingSummary: String {
        let names = model.report.blockingChecks.map(\.title)
        guard !names.isEmpty else { return "Open Setup to see what's missing." }
        return "Needs attention: " + names.joined(separator: ", ") + "."
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "externaldrive")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No NTFS drives connected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Plug one in and it will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Setup…") { openWindow(id: WindowID.setup) }
                .buttonStyle(.borderless)
            Button("Settings…") { openSettings() }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct ErrorBanner: View {
    let error: AppModel.PresentableError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.title)
                    .font(.callout.weight(.medium))
                if let detail = error.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.red.opacity(0.08))
    }
}
