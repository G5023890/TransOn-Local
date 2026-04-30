import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                controller.translateSelectedText()
            } label: {
                Label("Translate Selected Text", systemImage: "text.viewfinder")
            }
            .disabled(controller.isWorking || !controller.status.ready)

            Button {
                controller.prepare()
            } label: {
                Label("Prepare / Update Model", systemImage: "arrow.down.circle")
            }
            .disabled(controller.isWorking)

            Divider()

            Picker("Target", selection: $controller.targetLanguage) {
                ForEach(LanguageCatalog.languages, id: \.self) { language in
                    Text(language).tag(language)
                }
            }

            Picker("Model", selection: $controller.selectedModelID) {
                ForEach(ModelCatalog.models) { model in
                    Text("\(model.displayName) \(model.quant)").tag(model.id)
                }
            }

            Picker("Hot key", selection: $controller.translationHotKeyID) {
                ForEach(HotKeyCatalog.options) { option in
                    Text(option.displayName).tag(option.id)
                }
            }

            Toggle("Auto source language", isOn: $controller.autoDetectSource)

            Divider()

            StatusBlock(status: controller.status, isWorking: controller.isWorking, error: controller.lastError)

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

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
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

                Spacer()

                Button(role: .destructive) {
                    controller.clearCache()
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
            }
            .disabled(controller.isWorking)

            Spacer()
        }
        .padding(24)
        .background(.ultraThinMaterial)
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
        }
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
