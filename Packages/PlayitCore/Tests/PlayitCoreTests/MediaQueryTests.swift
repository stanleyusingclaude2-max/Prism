import Foundation
import XCTest
@testable import PlayitCore

final class MediaQueryTests: XCTestCase {
    private func item(
        _ path: String,
        kind: MediaKind = .video,
        bytes: Int64 = 1,
        date: TimeInterval = 0,
        duration: Double? = nil
    ) -> MediaItem {
        MediaItem(
            relativePath: path,
            kind: kind,
            byteCount: bytes,
            importedAt: Date(timeIntervalSince1970: date),
            modifiedAt: Date(timeIntervalSince1970: date),
            duration: duration
        )
    }

    func testGlobalKindFilterTraversesAllFolders() {
        let input = [
            item("root.mp4"),
            item("旅行/海边/a.mp4"),
            item("其他/城市场景/b.jpg", kind: .image)
        ]
        XCTAssertEqual(MediaQuery(kind: .video).apply(to: input).map(\.id), ["root.mp4", "旅行/海边/a.mp4"])
        XCTAssertEqual(MediaQuery(kind: .image).apply(to: input).map(\.id), ["其他/城市场景/b.jpg"])
        XCTAssertEqual(MediaQuery().apply(to: input).count, 3)
        XCTAssertEqual(MediaQuery(folderPath: "").apply(to: input).count, 3)
    }

    func testFolderIncludesDescendantsButNotSimilarPrefix() {
        let input = [
            item("旅行/a.mp4"),
            item("旅行/海边/b.mp4"),
            item("旅行/海边/日落/c.mp4"),
            item("旅行备份/d.mp4"),
            item("其他/旅行/e.mp4"),
            item("root.mp4")
        ]
        XCTAssertEqual(MediaQuery(folderPath: "旅行").apply(to: input).map(\.id), [
            "旅行/a.mp4", "旅行/海边/b.mp4", "旅行/海边/日落/c.mp4"
        ])
        XCTAssertEqual(MediaQuery(folderPath: "/旅行/海边/").apply(to: input).map(\.id), [
            "旅行/海边/b.mp4", "旅行/海边/日落/c.mp4"
        ])
    }

    func testFilenameSearchIsCaseAndDiacriticInsensitive() {
        let input = [item("Café_01.MP4"), item("folder/CAFE_02.mp4"), item("Cafe/other.mp4")]
        XCTAssertEqual(MediaQuery(search: "  cafe \n").apply(to: input).map(\.filename), ["Café_01.MP4", "CAFE_02.mp4"])
        // Matching folder names must not make an unrelated filename a result.
        XCTAssertEqual(MediaQuery(search: "Cafe").apply(to: [input[2]]).count, 0)
    }

    func testChineseSearchCombinesWithMediaAndFolderFilters() {
        let input = [
            item("旅行/海边冲浪.mp4"),
            item("旅行/海边定格.jpg", kind: .image),
            item("其他/海边夜景.mp4"),
            item("旅行/森林.mp4")
        ]
        let query = MediaQuery(kind: .video, search: "海边", folderPath: "旅行")
        XCTAssertEqual(query.apply(to: input).map(\.id), ["旅行/海边冲浪.mp4"])
    }

    func testNamesSortNaturallyInBothDirections() {
        let input = [item("clip10.mp4"), item("clip2.mp4"), item("clip1.mp4")]
        XCTAssertEqual(MediaQuery(sort: .name, direction: .ascending).apply(to: input).map(\.filename), [
            "clip1.mp4", "clip2.mp4", "clip10.mp4"
        ])
        XCTAssertEqual(MediaQuery(sort: .name, direction: .descending).apply(to: input).map(\.filename), [
            "clip10.mp4", "clip2.mp4", "clip1.mp4"
        ])
    }

    func testEquivalentSortKeysPreserveOriginalOrder() {
        let input = [item("b/a.mp4"), item("a/A.mp4"), item("c/a.mp4")]
        for direction in SortDirection.allCases {
            for sort in [MediaSort.name, .importedAt, .duration, .fileSize] {
                XCTAssertEqual(MediaQuery(sort: sort, direction: direction).apply(to: input).map(\.id), input.map(\.id))
            }
        }
    }

    func testDurationUnknownValuesAlwaysFollowKnownValues() {
        let input = [
            item("unknown.mp4"),
            item("long.mp4", duration: 20),
            item("nan.mp4", duration: .nan),
            item("short.mp4", duration: 1),
            item("infinite.mp4", duration: .infinity),
            item("negative.mp4", duration: -1),
            item("zero.mp4", duration: 0)
        ]
        let unknownNames = ["unknown.mp4", "nan.mp4", "infinite.mp4", "negative.mp4"]
        XCTAssertEqual(MediaQuery(sort: .duration, direction: .ascending).apply(to: input).map(\.filename), [
            "zero.mp4", "short.mp4", "long.mp4"
        ] + unknownNames)
        XCTAssertEqual(MediaQuery(sort: .duration, direction: .descending).apply(to: input).map(\.filename), [
            "long.mp4", "short.mp4", "zero.mp4"
        ] + unknownNames)
    }

    func testDateAndSizeSorts() {
        let input = [item("small-new.mp4", bytes: 10, date: 100), item("large-old.mp4", bytes: 100, date: 1)]
        XCTAssertEqual(MediaQuery(sort: .importedAt, direction: .descending).apply(to: input).first?.filename, "small-new.mp4")
        XCTAssertEqual(MediaQuery(sort: .fileSize, direction: .descending).apply(to: input).first?.filename, "large-old.mp4")
        XCTAssertEqual(MediaQuery(sort: .fileSize, direction: .ascending).apply(to: input).first?.filename, "small-new.mp4")
    }
}
