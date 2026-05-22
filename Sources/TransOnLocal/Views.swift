import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                controller.translateSelectedText()
            } label: {
                Label("Translate Selected Text", systemImage: "text.viewfinder")
            }
            .disabled(controller.isWorking || !controller.status.ready)

            if controller.currentWork.isFileTranslation {
                Button(role: .destructive) {
                    controller.cancelCurrentWork()
                } label: {
                    Label("Cancel Translating", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    controller.translateFile()
                } label: {
                    Label("Translate File", systemImage: "doc.text.viewfinder")
                }
                .disabled(controller.isWorking || !controller.status.ready)
            }

            Divider()

            Picker("Target", selection: $controller.targetLanguage) {
                ForEach(LanguageCatalog.languages, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
            .disabled(controller.isWorking)

            MenuStatusRow(status: controller.status, isWorking: controller.isWorking, error: controller.lastError)

            Divider()

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .padding(8)
        .frame(width: 300)
    }
}

struct MenuStatusRow: View {
    let status: LocalModelStatus
    let isWorking: Bool
    let error: String?

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
        }
        .labelStyle(.titleAndIcon)
    }

    private var title: String {
        if let error, !error.isEmpty {
            return "Needs attention: \(error)"
        }
        if isWorking {
            if let progress = status.downloadProgress {
                if let fraction = progress.fraction {
                    return "Working... \(fraction.formatted(.percent.precision(.fractionLength(0))))"
                }
                return "Working..."
            }
            return "Working..."
        }
        return status.ready ? "Ready" : "Not ready"
    }

    private var iconName: String {
        if error != nil {
            return "exclamationmark.triangle.fill"
        }
        if isWorking {
            return "arrow.triangle.2.circlepath"
        }
        return status.ready ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var iconColor: Color {
        if error != nil {
            return .red
        }
        if isWorking {
            return .blue
        }
        return status.ready ? .green : .secondary
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("TransOn Local", systemImage: "text.bubble")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await controller.refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                GlassGroup {
                    Picker("Target language", selection: $controller.targetLanguage) {
                        ForEach(LanguageCatalog.languages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }

                    Toggle("Auto-detect source language", isOn: $controller.autoDetectSource)

                    Picker("Model", selection: $controller.selectedModelID) {
                        ForEach(ModelCatalog.models) { model in
                            Text("\(model.displayName) \(model.quant) - \(model.sizeGB, specifier: "%.2f") GB").tag(model.id)
                        }
                    }

                    Picker("Hot key", selection: $controller.translationHotKeyID) {
                        ForEach(HotKeyCatalog.options) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                }

                GlassGroup {
                    StatusBlock(status: controller.status, isWorking: controller.isWorking, error: controller.lastError)

                    if let modelPath = controller.status.modelPath {
                        InfoRow(label: "Model", value: modelPath)
                    }
                    if let llamaPath = controller.status.llamaCliPath {
                        InfoRow(label: "llama runtime", value: llamaPath)
                    }
                    InfoRow(label: "Cache", value: ByteCountFormatter.string(fromByteCount: controller.status.modelBytes, countStyle: .file))
                }

                HStack {
                    if controller.currentWork == .maintenance {
                        Button(role: .destructive) {
                            controller.cancelCurrentWork()
                        } label: {
                            Label("Cancel Task", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            controller.prepare()
                        } label: {
                            Label("Prepare / Update", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            controller.downloadSelectedModel()
                        } label: {
                            Label("Download Model", systemImage: "square.and.arrow.down")
                        }
                    }

                    Spacer()

                    Button(role: .destructive) {
                        controller.clearCache()
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                    .disabled(controller.isWorking)
                }

                GlassGroup {
                    UpdateCenterBlock(result: controller.updateCheck)

                    HStack {
                        Button {
                            controller.checkUpdates()
                        } label: {
                            Label("Check Updates", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(controller.isWorking)

                        if controller.updateCheck.model.summary == "Installed, update state unknown" {
                            Button {
                                controller.repairModelMetadata()
                            } label: {
                                Label("Repair Metadata", systemImage: "wrench.and.screwdriver")
                            }
                            .disabled(controller.isWorking)
                        }

                        if controller.updateCheck.model.status == .updateAvailable {
                            Button {
                                controller.updateSelectedModel()
                            } label: {
                                Label("Update Model", systemImage: "square.and.arrow.down.badge.clock")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.isWorking)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .background(.ultraThinMaterial)
    }
}

struct UpdateCenterBlock: View {
    let result: UpdateCheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Updates", systemImage: "arrow.down.circle")
                .font(.headline)

            UpdateComponentRow(status: result.model, showsDetail: true)
            UpdateComponentRow(status: result.runtime, showsDetail: false)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Next: model catalog, prompts, and performance profiles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct UpdateComponentRow: View {
    let status: UpdateComponentStatus
    let showsDetail: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(status.summary)")
                    .font(.caption.weight(.semibold))
                if showsDetail || status.status == .updateAvailable || status.status == .checkFailed {
                    Text(status.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var title: String {
        switch status.component {
        case .model:
            return "Model"
        case .runtime:
            return "Runtime"
        case .modelCatalog:
            return "Catalog"
        case .prompts:
            return "Prompts"
        case .performanceProfiles:
            return "Profiles"
        }
    }

    private var iconName: String {
        if status.component == .runtime, status.summary == "Installed" {
            return "checkmark.circle.fill"
        }

        switch status.status {
        case .upToDate:
            return "checkmark.circle.fill"
        case .updateAvailable:
            return "arrow.down.circle.fill"
        case .notDownloaded:
            return "icloud.and.arrow.down"
        case .unknown:
            return "questionmark.circle"
        case .checkFailed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        if status.component == .runtime, status.summary == "Installed" {
            return .green
        }

        switch status.status {
        case .upToDate:
            return .green
        case .updateAvailable:
            return .blue
        case .notDownloaded, .unknown:
            return .secondary
        case .checkFailed:
            return .red
        }
    }
}

struct StatusBlock: View {
    let status: LocalModelStatus
    let isWorking: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: status.ready ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status.ready ? .green : .secondary)
                Text(isWorking ? "Working..." : status.summary)
                    .font(.headline)
            }
            Text(error ?? status.detail)
                .font(.caption)
                .foregroundColor(error == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = status.downloadProgress, progress.phase != .failed {
                DownloadProgressBlock(progress: progress)
            }
        }
    }
}

struct DownloadProgressBlock: View {
    let progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                Text("\(percent(fraction)) · \(bytes(progress.downloadedBytes)) of \(bytes(progress.totalBytes ?? 0)) · \(bytesPerSecond(progress.speedBytesPerSecond))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("\(bytes(progress.downloadedBytes)) · \(bytesPerSecond(progress.speedBytesPerSecond))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("File \(progress.fileIndex) of \(progress.fileCount): \(progress.fileName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.top, 4)
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func bytesPerSecond(_ value: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))/s"
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}
