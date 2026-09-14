import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 我的 > 题库 settings: local-bank status, 更新题库 / 导入题库 / 删除题库
/// (re-crawl / import a package / wipe the local bank) and a separate 日志
/// section with 日志导出 (plain-text export of the crawl log — per-paper step
/// outcomes, saved as crawl_log.jsonl during crawls). Creates its own
/// PracticeBankViewModel (a second instance is harmless — the store commits
/// atomically per paper with meta.papers progress).
struct PracticeBankSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PracticeBankViewModel?
    @State private var logStatus: String?
    @State private var confirmDelete = false
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importStatus: String?

    var body: some View {
        Section {
            Button("更新题库") {
                Task { await vm?.updateBank() }
            }
            .disabled(isCrawling)
            if isCrawling, let progress = crawlProgress {
                ProgressView(value: Double(progress.index), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                if progress.total > 0 {
                    Text("正在爬取 \(progress.paperName)（\(progress.index)/\(progress.total)）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("删除题库", role: .destructive) {
                confirmDelete = true
            }
            .disabled(isCrawling)
            // 导入题库:从「文件」App 选一个题库包(.zip,由 apps/bank 的
            // `npm run snapshot` 产出),校验通过后整体替换本地库——全程零
            // 网络,用来在断网/上游不可达时把环境拉起来。
            Button("导入题库") {
                showImporter = true
            }
            .disabled(isCrawling || isImporting)
            if isImporting {
                ProgressView()
                Text("正在校验并导入题库包…（约 1 分钟，请勿退出）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let importStatus {
                Text(importStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("题库")
        } footer: {
            // 三条路径都会清 session+progress(含错题):更新/删除走
            // deleteBank/VM,导入走 notifyBankChanged(AppState 里统一清)。
            // footer 必须三条都明示,只写「更新或删除」会让导入静默清空。
            Text("更新、导入或删除题库会同时清空练习进度与错题本")
        }
        .confirmationDialog(
            "删除本地题库？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除题库", role: .destructive) {
                deleteBank()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地题库将被清空（含爬取日志），再次进入练习页会重新从蓝鲸平台爬取全部试卷，每张新卷占用一次作答机会并自动结束。删除题库会同时清空练习进度与错题本。")
        }

        Section {
            Button("日志导出") {
                exportBankLog()
            }
            if let logStatus {
                Text(logStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("日志")
        }
        .onAppear {
            if vm == nil {
                vm = PracticeBankViewModel(appState: appState)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importBank(from: url) }
            case .failure(let error):
                importStatus = "选择文件失败：\(error.localizedDescription)"
            }
        }
    }

    /// 导入题库包并整体替换本地库。`fileImporter` 交回来的是
    /// security-scoped URL:不 start/stop 访问,真机上读这个 78 MB 的包会
    /// 直接失败(模拟器不暴露这个问题,所以必须在真机上验一次)。
    private func importBank(from url: URL) async {
        guard let database = appState.bankDatabase else {
            importStatus = "导入失败：本地库不可用"
            return
        }
        isImporting = true
        importStatus = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            isImporting = false
        }
        do {
            let summary = try await BankImporter.run(
                packageAt: url, database: database, storage: appState.bankStorage
            )
            // 追加清空提示:notifyBankChanged 会清掉练习会话与进度注册表
            // (错题搭车其中),这条副作用必须告诉用户——summary.message 由
            // BankImporter 生成,不含清档语义,故在这里拼接。
            importStatus = summary.message + "（练习进度与错题本已清空）"
            // 练习 tab 的 VM 收到信号后重读本地库(不再重爬)。
            appState.notifyBankChanged()
        } catch {
            importStatus = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Wipe the local bank (storage + crawl log) and notify every bank VM
    /// (练习 tab's instance included) via AppState.bankResetVersion.
    private func deleteBank() {
        vm?.bankWasDeleted()
        appState.deleteBank()
    }

    /// Write the crawl log (every paper's step outcomes) to a date-time named
    /// txt and hand it to the system share sheet (save to Files / AirDrop / …).
    private func exportBankLog() {
        guard let vm else { return }
        let entries = vm.bankStore.loadCrawlLog()
        guard !entries.isEmpty else {
            logStatus = "暂无爬取日志（完成一次爬取后生成）"
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BankExport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: BankLogic.exportFileName())
        do {
            try BankLogic.exportLogText(entries).write(to: url, atomically: true, encoding: .utf8)
            logStatus = nil
            presentShareSheet(for: url)
        } catch {
            logStatus = "导出失败：\(error.localizedDescription)"
        }
    }

    /// Present `UIActivityViewController` from the active window's top view
    /// controller instead of a SwiftUI `.sheet`.
    ///
    /// Why not a sheet: this row is List content, and on the *first*
    /// presentation of the session SwiftUI hosts that sheet's content twice —
    /// two `PresentationHostingController`s alive at once, and the wrapper's
    /// `makeUIViewController` called twice. UIKit refuses the second
    /// `present` ("already presenting"), and the collision tears the share
    /// sheet down ~1s after it appears — the "跳出分享界面又迅速关掉" symptom.
    /// It isn't about the activity controller: a plain `UIViewController` in
    /// the same sheet is hosted twice all the same, and a plain `@State` flag
    /// instead of the derived binding doesn't change it either. Presented
    /// from here it's a single `present` call with nothing racing it, and the
    /// row still writes its tap-time-named txt first.
    private func presentShareSheet(for url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow ?? scene.windows.first,
              var top = window.rootViewController
        else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            // iPad: the share sheet is a popover and needs an anchor. The row
            // that triggered it isn't reachable from here, so point at the
            // middle of the screen and drop the arrow rather than point it at
            // an unrelated bar button.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private var isCrawling: Bool {
        if case .downloading = vm?.phase { return true }
        return false
    }

    private var crawlProgress: PracticeUpstreamClient.CrawlProgress? {
        if case .downloading(let progress) = vm?.phase { return progress }
        return nil
    }
}
