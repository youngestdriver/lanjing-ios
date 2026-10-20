import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 槽位详情页：试听、从文件 App 选择、恢复系统默认。选择后先复制到临时
/// 目录并释放 security scope，再进截取页。
struct CustomSoundView: View {
    let slot: SoundSlot

    @Environment(AppState.self) private var appState
    @State private var customURL: URL?
    @State private var showingImporter = false
    @State private var pendingTrim: PendingTrim?
    @State private var errorMessage: String?
    @State private var showingResetConfirmation = false
    @State private var isWorking = false
    /// 试听必须由 @State 持有：临时 output 在按钮 action 返回时释放，
    /// 它持有的 AVAudioPlayer 也会随之释放，试听会被截断。
    @State private var previewOutput: DefaultQuizSoundOutput?

    private struct PendingTrim: Identifiable {
        let id = UUID()
        let url: URL
        let duration: TimeInterval
    }

    private var title: String {
        switch slot {
        case .correct: "答对音效"
        case .wrong: "答错音效"
        }
    }

    var body: some View {
        List {
            Section("当前音效") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
                Button("试听") {
                    if previewOutput == nil {
                        previewOutput = DefaultQuizSoundOutput(store: appState.customSoundStore)
                    }
                    previewOutput?.preview(slot)
                }
                .accessibilityIdentifier("preview-\(slot.rawValue)-sound")
            }

            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("选择音频文件", systemImage: "folder")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("choose-\(slot.rawValue)-sound")

                if customURL != nil {
                    Button("恢复系统默认", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .accessibilityIdentifier("reset-\(slot.rawValue)-sound")
                }
            } footer: {
                Text("支持文件 App 中的音频，截取最长 5 秒。关闭「答题音效」后不会播放。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isWorking {
                ProgressView("处理中…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await prepareImport(from: url) }
            case .failure(let error):
                errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(item: $pendingTrim) { pending in
            SoundTrimView(
                slot: slot,
                sourceURL: pending.url,
                assetDuration: pending.duration,
                store: appState.customSoundStore
            ) {
                refresh()
            }
            .onDisappear {
                try? FileManager.default.removeItem(at: pending.url)
            }
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("移除自定义音效？", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("恢复系统默认", role: .destructive) { resetToDefault() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该事件将恢复播放系统提示音。")
        }
        .onAppear { refresh() }
    }

    private var statusText: String {
        guard let customURL, let duration = Self.duration(of: customURL) else {
            return "系统默认"
        }
        return String(format: "自定义 · %.1f 秒", duration)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func refresh() {
        customURL = appState.customSoundStore.url(for: slot)
    }

    private func resetToDefault() {
        do {
            try appState.customSoundStore.remove(for: slot)
            refresh()
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    private func prepareImport(from url: URL) async {
        isWorking = true
        defer { isWorking = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "sound-import-\(UUID().uuidString).\(ext)")

        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            let duration = try await SoundClipExporter.assetDuration(at: tempURL)
            guard SoundTrimRange.initial(for: duration) != nil else {
                throw SoundClipError.tooShort
            }
            pendingTrim = PendingTrim(url: tempURL, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        (try? AVAudioPlayer(contentsOf: url))?.duration
    }
}

/// 「我的 > 答题设置」里的状态行：文件存在显示时长，否则显示系统默认。
struct SoundStatusRow: View {
    let title: String
    let slot: SoundSlot

    @Environment(AppState.self) private var appState
    @State private var duration: TimeInterval?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(duration.map { String(format: "自定义 · %.1f 秒", $0) } ?? "系统默认")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("\(slot.rawValue)-sound-row")
        .onAppear { refresh() }
    }

    private func refresh() {
        guard let url = appState.customSoundStore.url(for: slot),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            duration = nil
            return
        }
        duration = player.duration
    }
}
