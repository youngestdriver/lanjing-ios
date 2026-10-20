import XCTest
@testable import LanjingQuiz

final class SoundTrimRangeTests: XCTestCase {

    func testInitialRangeRejectsUnreadableOrTooShortAudio() {
        XCTAssertNil(SoundTrimRange.initial(for: 0.49))
        XCTAssertNil(SoundTrimRange.initial(for: .nan))
        XCTAssertNil(SoundTrimRange.initial(for: .infinity))
    }

    func testInitialRangeTakesWholeShortAudio() {
        XCTAssertEqual(SoundTrimRange.initial(for: 0.5), SoundTrimRange(start: 0, end: 0.5))
        XCTAssertEqual(SoundTrimRange.initial(for: 3), SoundTrimRange(start: 0, end: 3))
    }

    func testInitialRangeCapsAtFiveSeconds() {
        XCTAssertEqual(SoundTrimRange.initial(for: 10), SoundTrimRange(start: 0, end: 5))
    }

    func testMovingStartKeepsLengthWithinBounds() {
        let range = SoundTrimRange(start: 0, end: 5)

        XCTAssertEqual(range.movingStart(to: 3, assetDuration: 10), SoundTrimRange(start: 3, end: 5))
        XCTAssertEqual(range.movingStart(to: 9, assetDuration: 10), SoundTrimRange(start: 4.5, end: 5))
        XCTAssertEqual(range.movingStart(to: -2, assetDuration: 10), SoundTrimRange(start: 0, end: 5))
    }

    func testMovingEndKeepsLengthWithinBounds() {
        let range = SoundTrimRange(start: 2, end: 4)

        XCTAssertEqual(range.movingEnd(to: 6, assetDuration: 10), SoundTrimRange(start: 2, end: 6))
        XCTAssertEqual(range.movingEnd(to: 9, assetDuration: 10), SoundTrimRange(start: 2, end: 7))
        XCTAssertEqual(range.movingEnd(to: 2.1, assetDuration: 10), SoundTrimRange(start: 2, end: 2.5))
        XCTAssertEqual(range.movingEnd(to: 0, assetDuration: 10), SoundTrimRange(start: 2, end: 2.5))
    }

    func testMovingStartStaysInsideAssetDuration() {
        let range = SoundTrimRange(start: 0, end: 5)
        XCTAssertEqual(range.movingStart(to: 100, assetDuration: 10), SoundTrimRange(start: 4.5, end: 5))
    }
}
