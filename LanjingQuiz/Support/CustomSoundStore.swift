import Foundation

/// 自定义音效的落盘槽位。文件存在 = 用户自定义；不存在 = 系统默认。
/// 不另设 UserDefaults 键，避免「设置说有、文件没了」的失同步。
protocol CustomSoundStoring: Sendable {
    /// 文件存在才返回 URL。
    func url(for slot: SoundSlot) -> URL?
    /// 读入临时产物并原子写入槽位文件；失败抛错、旧文件不动。
    func install(from tempURL: URL, for slot: SoundSlot) throws
    func remove(for slot: SoundSlot) throws
}

struct FileManagerCustomSoundStore: CustomSoundStoring {

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/sounds", directoryHint: .isDirectory)
    }

    func url(for slot: SoundSlot) -> URL? {
        let url = directory.appending(path: slot.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func install(from tempURL: URL, for slot: SoundSlot) throws {
        let data = try Data(contentsOf: tempURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: slot.fileName), options: .atomic)
    }

    func remove(for slot: SoundSlot) throws {
        let url = directory.appending(path: slot.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
