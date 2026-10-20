import XCTest
@testable import LanjingQuiz

final class CustomSoundStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "CustomSoundStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> FileManagerCustomSoundStore {
        FileManagerCustomSoundStore(directory: dir)
    }

    private func makeFile(_ name: String, contents: Data = Data([1, 2, 3])) throws -> URL {
        let url = dir.appending(path: name)
        try contents.write(to: url)
        return url
    }

    func testSlotFileNamesArePinned() {
        XCTAssertEqual(SoundSlot.correct.fileName, "correct.m4a")
        XCTAssertEqual(SoundSlot.wrong.fileName, "wrong.m4a")
    }

    func testURLIsNilWithoutFile() {
        XCTAssertNil(store().url(for: .correct))
    }

    func testInstallThenURLReturnsFile() throws {
        let source = try makeFile("source.m4a")
        try store().install(from: source, for: .correct)

        let installed = try XCTUnwrap(store().url(for: .correct))
        XCTAssertEqual(installed.lastPathComponent, "correct.m4a")
        XCTAssertEqual(try Data(contentsOf: installed), Data([1, 2, 3]))
        XCTAssertNil(store().url(for: .wrong), "安装一个槽位不得影响另一个")
    }

    func testInstallReplacesExistingFile() throws {
        let first = try makeFile("first.m4a", contents: Data([1]))
        let second = try makeFile("second.m4a", contents: Data([2, 2]))

        try store().install(from: first, for: .wrong)
        try store().install(from: second, for: .wrong)

        let installed = try XCTUnwrap(store().url(for: .wrong))
        XCTAssertEqual(try Data(contentsOf: installed), Data([2, 2]))
    }

    func testInstallCreatesDirectory() throws {
        let nested = dir.appending(path: "nested/deeper", directoryHint: .isDirectory)
        let source = try makeFile("source.m4a")
        let nestedStore = FileManagerCustomSoundStore(directory: nested)

        try nestedStore.install(from: source, for: .correct)

        XCTAssertNotNil(nestedStore.url(for: .correct))
    }

    func testRemoveDeletesFileAndIsIdempotent() throws {
        let source = try makeFile("source.m4a")
        try store().install(from: source, for: .correct)

        try store().remove(for: .correct)
        XCTAssertNil(store().url(for: .correct))
        XCTAssertNoThrow(try store().remove(for: .correct), "重复删除不得抛错")
    }
}
