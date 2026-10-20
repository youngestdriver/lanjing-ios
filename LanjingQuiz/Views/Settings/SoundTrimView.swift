import AVFoundation
import SwiftUI

/// 导入音频的截取页：双滑块选起止（0.5–5 秒），试听选中片段，保存时
/// 转码为 m4a 并原子写入槽位。
struct SoundTrimView: View {
    let slot: SoundSlot
    let sourceURL: URL
    let assetDuration: TimeInterval
    let store: any CustomSoundStoring
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var range: SoundTrimRange
    @State private var previewer: TrimPreviewer?
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(slot: SoundSlot, sourceURL: URL, assetDuration: TimeInterval,
         store: any CustomSoundStoring, onSaved: @escaping () -> Void) {
        self.slot = slot
        self.sourceURL = sourceURL
        self.assetDuration = assetDuration
        self.store = store
        self.onSaved = onSaved
        _range = State(initialValue: SoundTrimRange.initial(for: assetDuration)
            ?? SoundTrimRange(start: 0, end: max(assetDuration, SoundTrimRange.minClipDuration)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("截取") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("起点 \(Self.timecode(range.start))")
                        Slider(
                            value: Binding(
                                get: { range.start },
                                set: { range = range.movingStart(to: $0, assetDuration: assetDuration) }
                            ),
                            in: 0...max(0, assetDuration - SoundTrimRange.minClipDuration),
                            step: 0.1
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("终点 \(Self.timecode(range.end))")
                        Slider(
                            value: Binding(
                                get: { range.end },
                                set: { range = range.movingEnd(to: $0, assetDuration: assetDuration) }
                            ),
                            in: SoundTrimRange.minClipDuration...assetDuration,
                            step: 0.1
                        )
                    }

                    HStack {
                        Text("选中")
                        Spacer()
                        Text(String(format: "%.1f 秒", range.duration))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("trim-duration")
                }

                Section {
                    Button {
                        previewSelection()
                    } label: {
                        Label("试听选中片段", systemImage: "play.circle")
                    }
                    .disabled(isExporting)
                    .accessibilityIdentifier("preview-trimmed-sound")
                } footer: {
                    Text("音频最长 5 秒，保存后会替换当前\(slotTitle)音效。")
                }
            }
            .navigationTitle("截取音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isExporting)
                }
            }
            .interactiveDismissDisabled(isExporting)
            .overlay {
                if isExporting {
                    ProgressView("截取中…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("截取失败", isPresented: errorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if previewer == nil {
                    previewer = TrimPreviewer()
                }
            }
            .onDisappear { previewer?.stop() }
        }
    }

    private var slotTitle: String {
        switch slot {
        case .correct: "答对"
        case .wrong: "答错"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func previewSelection() {
        guard let previewer,
              previewer.play(url: sourceURL, from: range.start, duration: range.duration) else {
            errorMessage = "无法播放该音频"
            return
        }
    }

    private func save() async {
        isExporting = true
        defer { isExporting = false }
        previewer?.stop()

        do {
            let clipURL = try await SoundClipExporter.export(from: sourceURL, range: range)
            defer { try? FileManager.default.removeItem(at: clipURL) }
            try store.install(from: clipURL, for: slot)
            onSaved()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let totalTenths = max(0, Int((seconds * 10).rounded()))
        let whole = totalTenths / 10
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}

/// 试听器独立成 @MainActor 类：持有 AVAudioPlayer 与自动停止任务，避免
/// 把非 Sendable 播放器塞进视图的 Task 捕获里。
@MainActor
private final class TrimPreviewer {
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(url: URL, from start: TimeInterval, duration: TimeInterval) -> Bool {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.currentTime = start
        guard player.play() else { return false }
        self.player = player

        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
        return true
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
    }
}
