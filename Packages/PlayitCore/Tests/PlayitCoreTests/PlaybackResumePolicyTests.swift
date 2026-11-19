import XCTest
@testable import PlayitCore

final class PlaybackResumePolicyTests: XCTestCase {
    func testMiddlePositionsOfLongerVideosAreRemembered() {
        XCTAssertEqual(PlaybackResumePolicy.storedPosition(position: 30, duration: 60), 30)
        XCTAssertEqual(PlaybackResumePolicy.storedPosition(position: 56.9, duration: 60), 56.9)
        XCTAssertEqual(PlaybackResumePolicy.storedPosition(position: 569, duration: 600), 569)
    }

    func testStartEndAndShortClipsAreForgotten() {
        XCTAssertNil(PlaybackResumePolicy.storedPosition(position: 2, duration: 60))
        XCTAssertNil(PlaybackResumePolicy.storedPosition(position: 57.5, duration: 60))
        // The closing 5% of a long video counts as finished.
        XCTAssertNil(PlaybackResumePolicy.storedPosition(position: 571, duration: 600))
        XCTAssertNil(PlaybackResumePolicy.storedPosition(position: 5, duration: 10))
    }

    func testInvalidNumbersAreForgotten() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(PlaybackResumePolicy.storedPosition(position: invalid, duration: 60))
            XCTAssertNil(PlaybackResumePolicy.storedPosition(position: 30, duration: invalid))
        }
    }

    func testResumeRevalidatesAgainstTheKnownDuration() {
        XCTAssertEqual(PlaybackResumePolicy.resumePosition(stored: 30, duration: 60), 30)
        XCTAssertNil(PlaybackResumePolicy.resumePosition(stored: 100, duration: 60))
        XCTAssertNil(PlaybackResumePolicy.resumePosition(stored: nil, duration: 60))
        XCTAssertNil(PlaybackResumePolicy.resumePosition(stored: 2, duration: nil))
    }

    func testUnknownDurationTrustsTheStoredPosition() {
        XCTAssertEqual(PlaybackResumePolicy.resumePosition(stored: 30, duration: nil), 30)
        XCTAssertEqual(PlaybackResumePolicy.resumePosition(stored: 30, duration: 0), 30)
        XCTAssertEqual(PlaybackResumePolicy.resumePosition(stored: 30, duration: .nan), 30)
    }

    func testPosterFrameSkipsAnOpeningFadeWithoutLeavingShortClips() {
        XCTAssertEqual(MediaPosterPolicy.time(duration: 60), 1)
        XCTAssertEqual(MediaPosterPolicy.time(duration: 3), 0.3, accuracy: 0.000_001)
        XCTAssertEqual(MediaPosterPolicy.time(duration: nil), 1)
        XCTAssertEqual(MediaPosterPolicy.time(duration: 0), 1)
        XCTAssertEqual(MediaPosterPolicy.time(duration: .nan), 1)
    }

    func testWatchedFractionAndTitleForLibraryRows() {
        var item = MediaItem(relativePath: "旅行/海边.片段.mp4", kind: .video, duration: 80, playbackPosition: 20)
        XCTAssertEqual(item.watchedFraction ?? -1, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(item.displayTitle, "海边.片段")
        item.playbackPosition = nil
        XCTAssertNil(item.watchedFraction)
        item.playbackPosition = 120
        XCTAssertEqual(item.watchedFraction, 1)
        XCTAssertEqual(MediaItem(relativePath: "clip", kind: .video).displayTitle, "clip")
    }
}
