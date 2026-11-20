import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @ObservedObject private var captureHotKey = GlobalCaptureHotKey.shared
    @State private var showingWidgets = false
    @State private var document: ArchiveDocument?
    @State private var exporting = false
    @State private var importing = false

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭设置").keyboardShortcut(.cancelAction)
                    .frame(minWidth: 28, minHeight: 28)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        localStorageSettings
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("快速记录").font(.headline)
                        Toggle("在任何应用中按 \(GlobalCaptureHotKey.shortcut) 记下一件事", isOn: Binding(get: { captureHotKey.enabled }, set: { captureHotKey.setEnabled($0) }))
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("globalCaptureToggle")
                        Text(captureHotKey.failure ?? "Let’s Do 运行时可用；关闭窗口后应用仍在运行即可。")
                            .font(.caption).foregroundStyle(captureHotKey.failure == nil ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    MacReminderSyncSettings(reminders: model.reminders)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("数据").font(.headline)
                        dataActions.buttonStyle(.borderless)
                        Text("备份包含任务和已保存的正文版本，可能有私人内容，请妥善保管。恢复只支持空的本机任务库，不会合并或覆盖已有任务。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("小组件布局预览", systemImage: "rectangle.3.group") { showingWidgets = true }
                        .buttonStyle(.borderless)
                    DisclosureGroup("存储详情") {
                        Text(model.storePath).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.callout)
                    HStack {
                        Text("Let’s Do").font(.callout.weight(.medium))
                        Text(appVersion).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text("只管去做").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
        }
        .frame(width: 460, height: 580)
        .sheet(isPresented: $showingWidgets) {
            WidgetGalleryView(model: model) { url in
                showingWidgets = false
                close()
                NSWorkspace.shared.open(url)
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "Lets-Do-backup") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let archive = try TaskArchive.decode(Data(contentsOf: url))
                model.perform { try $0.restoreIntoEmptyLocalStore(archive) }
            } catch { model.error = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var dataActions: some View {
        Button("导出 JSON 备份…", systemImage: "square.and.arrow.up") {
            model.perform { store in document = try ArchiveDocument(data: store.archive().encoded()); exporting = true }
        }.disabled(!model.loaded)
        Button("从 JSON 备份恢复…", systemImage: "square.and.arrow.down") { importing = true }
            .disabled(!model.loaded)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info?["CFBundleVersion"] as? String, build != version else { return "版本 \(version)" }
        return "版本 \(version)（\(build)）"
    }

    @ViewBuilder
    private var localStorageSettings: some View {
        Label("本机存储", systemImage: "internaldrive").font(.headline)
        Text("任务库保存在这台 Mac 上，可以导出 JSON 备份。")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !model.loaded {
            Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Button("检查本机存储") {
            Task {
                if model.loaded { model.reload() } else { await model.start() }
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("checkLocalStorage")
    }
}

struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
