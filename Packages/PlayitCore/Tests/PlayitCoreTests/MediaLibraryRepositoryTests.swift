import Foundation
import XCTest
@testable import PlayitCore

final class MediaLibraryRepositoryTests: XCTestCase {
    private var fixture: URL!
    private var root: URL!
    private var sources: URL!
    private var repository: MediaLibraryRepository!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("playit-tests-" + UUID().uuidString)
        root = fixture.appendingPathComponent("Library")
        sources = fixture.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        repository = MediaLibraryRepository(rootURL: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixture)
    }

    private func source(_ name: String, bytes: [UInt8] = [1, 2, 3, 4]) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testImportCopiesOriginalAndDisambiguatesNames() throws {
        let input = try source("海边.mp4")
        let first = try repository.importFile(from: input)
        let second = try repository.importFile(from: input)
        XCTAssertEqual(first.filename, "海边.mp4")
        XCTAssertEqual(second.filename, "海边 (2).mp4")
        XCTAssertEqual(try Data(contentsOf: input), Data([1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: repository.url(for: first)), Data([1, 2, 3, 4]))
        XCTAssertEqual(try repository.scan().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testPhotoProviderFileUsesSelectedNameInDestinationFolder() throws {
        let temporary = try source("provider-file.tmp")
        _ = try repository.createFolder(named: "骑行")
        let first = try repository.importFile(from: temporary, named: "转弯.mov", into: "骑行")
        let second = try repository.importFile(from: temporary, named: "转弯.mov", into: "骑行")
        XCTAssertEqual(first.relativePath, "骑行/转弯.mov")
        XCTAssertEqual(first.kind, .video)
        XCTAssertEqual(second.filename, "转弯 (2).mov")
        try FileManager.default.removeItem(at: temporary)
        XCTAssertEqual(try Data(contentsOf: repository.url(for: first)), Data([1, 2, 3, 4]))
        XCTAssertEqual(try repository.scan().count, 2)
    }

    func testScanClassifiesCommonExtensionsAndSkipsHiddenOrTemporaryFiles() throws {
        _ = try repository.scan()
        for ext in ["MP4", "mov", "mkv", "avi", "webm", "m2ts", "JPG", "png", "heic", "webp", "bmp"] {
            try Data([0]).write(to: root.appendingPathComponent("sample." + ext))
        }
        try Data([0]).write(to: root.appendingPathComponent("readme.txt"))
        try Data([0]).write(to: root.appendingPathComponent("video.mp4.part"))
        try Data([0]).write(to: root.appendingPathComponent(".hidden.mp4"))
        let hidden = root.appendingPathComponent(".incoming")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data([0]).write(to: hidden.appendingPathComponent("incomplete.mp4"))
        let scanned = try repository.scan()
        XCTAssertEqual(scanned.count, 11)
        XCTAssertEqual(scanned.filter { $0.kind == .video }.count, 6)
        XCTAssertEqual(scanned.filter { $0.kind == .image }.count, 5)
    }

    func testFoldersIncludeDescendantCountsAndEmptyFolders() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "海边", in: "旅行")
        _ = try repository.createFolder(named: "空文件夹")
        _ = try repository.importFile(from: source("clip.mp4"), into: "旅行/海边")
        _ = try repository.importFile(from: source("image.jpg"), into: "旅行")
        let folders = try repository.folders()
        let travel = try XCTUnwrap(folders.first { $0.path == "旅行" })
        XCTAssertEqual(travel.mediaCount, 2)
        XCTAssertEqual(travel.videoCount, 1)
        XCTAssertEqual(travel.imageCount, 1)
        XCTAssertEqual(folders.first { $0.path == "空文件夹" }?.mediaCount, 0)
        XCTAssertEqual(try repository.folders(in: "旅行").map(\.path), ["旅行/海边"])
    }

    func testRenamePreservesExtensionAndRejectsCollisions() throws {
        let first = try repository.importFile(from: source("first.mp4"))
        let other = try repository.importFile(from: source("other.mp4", bytes: [9]))
        let renamed = try repository.rename(item: first, to: "新的名称")
        XCTAssertEqual(renamed.filename, "新的名称.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url(for: first).path))
        XCTAssertThrowsError(try repository.rename(item: renamed, to: other.filename))
        XCTAssertEqual(try Data(contentsOf: repository.url(for: other)), Data([9]))
        XCTAssertEqual(try repository.scan().count, 2)
    }

    func testMoveValidatesEntireBatchBeforeChangingAnyFiles() throws {
        _ = try repository.createFolder(named: "目标")
        let first = try repository.importFile(from: source("first.mp4"))
        let second = try repository.importFile(from: source("second.mp4"))
        _ = try repository.importFile(from: source("second.mp4"), into: "目标")
        XCTAssertThrowsError(try repository.move(items: [first, second], to: "目标"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url(for: second).path))
        let moved = try repository.move(items: [first, first], to: "目标")
        XCTAssertEqual(moved.map(\.relativePath), ["目标/first.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url(for: first).path))
        XCTAssertEqual(try repository.scan().count, 3)
    }

    func testImportDatesAndDecoderMetadataSurviveReloadRenameAndMove() throws {
        _ = try repository.createFolder(named: "目标")
        let imported = try repository.importFile(from: source("clip.mp4"))
        try repository.setMetadata(for: imported, duration: 12.5, pixelWidth: 1920, pixelHeight: 1080)
        let renamed = try repository.rename(item: imported, to: "renamed")
        let moved = try XCTUnwrap(repository.move(items: [renamed], to: "目标").first)
        let reloaded = MediaLibraryRepository(rootURL: root)
        let result = try XCTUnwrap(reloaded.scan().first)
        XCTAssertEqual(result.id, moved.id)
        XCTAssertEqual(result.importedAt.timeIntervalSince1970, imported.importedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(result.duration, 12.5)
        XCTAssertEqual(result.pixelWidth, 1920)
        XCTAssertEqual(result.pixelHeight, 1080)
    }

    func testReplacedFilesInvalidateDecoderMetadata() throws {
        let imported = try repository.importFile(from: source("clip.mp4"))
        try repository.setMetadata(for: imported, duration: 12.5, pixelWidth: 1920, pixelHeight: 1080)
        try Data([8, 9]).write(to: repository.url(for: imported))
        let result = try XCTUnwrap(repository.scan().first)
        XCTAssertNil(result.duration)
        XCTAssertNil(result.pixelWidth)
        XCTAssertEqual(result.byteCount, 2)
    }

    func testBatchMetadataPersistsAndSkipsReplacedOrRemovedFiles() throws {
        var video = try repository.importFile(from: source("a.mp4"))
        var photo = try repository.importFile(from: source("b.jpg"))
        var replaced = try repository.importFile(from: source("c.mp4"))
        var removed = try repository.importFile(from: source("d.mp4"))
        try Data([8, 9]).write(to: repository.url(for: replaced))
        try FileManager.default.removeItem(at: repository.url(for: removed))

        video.duration = 12.5
        video.pixelWidth = 1920
        video.pixelHeight = 1080
        photo.pixelWidth = 4032
        photo.pixelHeight = 3024
        replaced.duration = 999
        replaced.pixelWidth = 999
        replaced.pixelHeight = 999
        removed.duration = 5
        try repository.setMetadata([video, photo, replaced, removed])

        let scanned = try MediaLibraryRepository(rootURL: root).scan()
        let results = Dictionary(uniqueKeysWithValues: scanned.map { ($0.filename, $0) })
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results["a.mp4"]?.duration, 12.5)
        XCTAssertEqual(results["a.mp4"]?.pixelWidth, 1920)
        XCTAssertEqual(results["a.mp4"]?.pixelHeight, 1080)
        XCTAssertEqual(results["b.jpg"]?.pixelWidth, 4032)
        XCTAssertEqual(results["b.jpg"]?.pixelHeight, 3024)
        XCTAssertNil(results["b.jpg"]?.duration)
        XCTAssertEqual(results["c.mp4"]?.byteCount, 2)
        XCTAssertNil(results["c.mp4"]?.duration)
        XCTAssertNil(results["c.mp4"]?.pixelWidth)
        XCTAssertNil(results["d.mp4"])
    }

    func testLateDecoderResultCannotAttachToAReplacedFile() throws {
        let oldVersion = try repository.importFile(from: source("clip.mp4"))
        try Data([8, 9]).write(to: repository.url(for: oldVersion))
        try repository.setMetadata(for: oldVersion, duration: 999, pixelWidth: 999, pixelHeight: 999)
        let result = try XCTUnwrap(repository.scan().first)
        XCTAssertEqual(result.byteCount, 2)
        XCTAssertNil(result.duration)
        XCTAssertNil(result.pixelWidth)
    }

    func testPlaybackPositionSurvivesReloadRenameAndMove() throws {
        _ = try repository.createFolder(named: "目标")
        let imported = try repository.importFile(from: source("clip.mp4"))
        let playedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.setPlaybackPosition(for: imported, position: 42.5, playedAt: playedAt)
        let renamed = try repository.rename(item: imported, to: "renamed")
        XCTAssertEqual(renamed.playbackPosition, 42.5)
        let moved = try XCTUnwrap(repository.move(items: [renamed], to: "目标").first)
        let reloaded = MediaLibraryRepository(rootURL: root)
        let result = try XCTUnwrap(reloaded.scan().first)
        XCTAssertEqual(result.id, moved.id)
        XCTAssertEqual(result.playbackPosition, 42.5)
        XCTAssertEqual(try XCTUnwrap(result.lastPlayedAt).timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        try reloaded.setPlaybackPosition(for: result, position: nil)
        let finished = try XCTUnwrap(reloaded.scan().first)
        XCTAssertNil(finished.playbackPosition)
        XCTAssertNotNil(finished.lastPlayedAt)
    }

    func testMetadataUpdatesKeepTheRememberedPosition() throws {
        let imported = try repository.importFile(from: source("clip.mp4"))
        try repository.setPlaybackPosition(for: imported, position: 20)
        try repository.setMetadata(for: imported, duration: 60, pixelWidth: 1920, pixelHeight: 1080)
        let result = try XCTUnwrap(repository.scan().first)
        XCTAssertEqual(result.playbackPosition, 20)
        XCTAssertEqual(result.duration, 60)
    }

    func testReplacedFilesForgetTheirPlaybackPosition() throws {
        let imported = try repository.importFile(from: source("clip.mp4"))
        try repository.setPlaybackPosition(for: imported, position: 42.5)
        try Data([8, 9]).write(to: repository.url(for: imported))
        XCTAssertNil(try XCTUnwrap(repository.scan().first).playbackPosition)
    }

    func testLatePositionCannotAttachToAReplacedFile() throws {
        let oldVersion = try repository.importFile(from: source("clip.mp4"))
        try Data([8, 9]).write(to: repository.url(for: oldVersion))
        try repository.setPlaybackPosition(for: oldVersion, position: 30)
        XCTAssertNil(try XCTUnwrap(repository.scan().first).playbackPosition)
    }

    func testMoveReturnValuesUseVerifiedPathsRatherThanMutableDisplayNames() throws {
        _ = try repository.createFolder(named: "目标")
        var imported = try repository.importFile(from: source("clip.mp4"))
        imported.filename = "different-display-name.mp4"
        let moved = try repository.move(items: [imported], to: "目标")
        XCTAssertEqual(moved.map(\.id), ["目标/clip.mp4"])
    }

    func testTraversalAndSymbolicLinksCannotEscapeLibrary() throws {
        let external = try source("outside.mp4")
        let item = try repository.importFile(from: source("inside.mp4"))
        XCTAssertThrowsError(try repository.createFolder(named: "../Escape"))
        XCTAssertThrowsError(try repository.createFolder(named: "valid", in: "../Sources"))
        XCTAssertThrowsError(try repository.move(items: [item], to: "../Sources"))
        let malicious = MediaItem(relativePath: "../Sources/outside.mp4", kind: .video)
        XCTAssertThrowsError(try repository.delete(items: [malicious]))
        XCTAssertTrue(repository.url(for: malicious).path.hasPrefix(root.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))

        let link = root.appendingPathComponent("shortcut.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let directoryLink = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: sources)
        XCTAssertEqual(try repository.scan().map(\.filename), ["inside.mp4"])
        XCTAssertThrowsError(try repository.importFile(from: external, into: "linked-folder"))
        XCTAssertTrue(try repository.folders().isEmpty)
    }

    func testDeleteHandlesDuplicateSelectionAndPreservesExternalSource() throws {
        let input = try source("clip.mp4")
        let imported = try repository.importFile(from: input)
        try repository.delete(items: [imported, imported])
        XCTAssertTrue(try repository.scan().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url(for: imported).path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".playit-delete-") })
    }

    func testDeletingLastVideoRemovesItsEmptyFolderButKeepsSibling() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "片段", in: "旅行")
        _ = try repository.createFolder(named: "保留", in: "旅行")
        let imported = try repository.importFile(from: source("clip.mp4"), into: "旅行/片段")
        try repository.delete(items: [imported])
        XCTAssertEqual(try repository.folders(in: "旅行").map(\.path), ["旅行/保留"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("旅行").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("旅行/片段").path))
    }

    func testDeleteLastFilePrunesItsEmptyAncestorChainAndPreservesRoot() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "海边", in: "旅行")
        _ = try repository.createFolder(named: "片段", in: "旅行/海边")
        _ = try repository.createFolder(named: "新建待导入")
        let imported = try repository.importFile(from: source("clip.mp4"), into: "旅行/海边/片段")

        try repository.delete(items: [imported])

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("旅行").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try repository.folders().map(\.path), ["新建待导入"])
        XCTAssertTrue(try repository.scan().isEmpty)
    }

    func testDeleteKeepsFoldersContainingAnyOtherDirectoryEntry() throws {
        let retainedNames = ["second.mp4", "photo.jpg", ".keep", "notes.txt", "caption.srt", "shortcut"]
        let external = try source("outside.mp4")
        var deleted: [MediaItem] = []
        for (index, retainedName) in retainedNames.enumerated() {
            let path = "folder\(index)"
            _ = try repository.createFolder(named: path)
            deleted.append(try repository.importFile(from: source("remove.mp4"), into: path))
            let retained = root.appendingPathComponent(path).appendingPathComponent(retainedName)
            if retainedName == "shortcut" {
                try FileManager.default.createSymbolicLink(at: retained, withDestinationURL: external)
            } else {
                try Data([9]).write(to: retained)
            }
        }

        try repository.delete(items: deleted)

        for (index, retainedName) in retainedNames.enumerated() {
            let directory = root.appendingPathComponent("folder\(index)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [retainedName])
        }
        XCTAssertEqual(try repository.folders().count, retainedNames.count)
        XCTAssertEqual(try Data(contentsOf: external), Data([1, 2, 3, 4]))
    }

    func testMovePrunesEmptySourceAncestorsAndKeepsDestination() throws {
        _ = try repository.createFolder(named: "来源")
        _ = try repository.createFolder(named: "子目录", in: "来源")
        _ = try repository.createFolder(named: "目标")
        let imported = try repository.importFile(from: source("clip.mp4"), into: "来源/子目录")

        let moved = try repository.move(items: [imported], to: "目标")

        XCTAssertEqual(moved.map(\.relativePath), ["目标/clip.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("来源").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("目标/clip.mp4").path))
        XCTAssertEqual(try repository.folders().map(\.path), ["目标"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testMoveIntoDescendantKeepsDestinationAndItsAncestors() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "目标", in: "旅行")
        let imported = try repository.importFile(from: source("clip.mp4"), into: "旅行")

        _ = try repository.move(items: [imported], to: "旅行/目标")

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("旅行/目标/clip.mp4").path))
        XCTAssertEqual(try repository.folders(in: "旅行").map(\.path), ["旅行/目标"])
    }

    func testExplicitFolderDeletePrunesItsNowEmptyAncestors() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "海边", in: "旅行")
        _ = try repository.importFile(from: source("clip.mp4"), into: "旅行/海边")

        try repository.deleteFolder(at: "旅行/海边")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("旅行").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(try repository.scan().isEmpty)
    }

    func testFailedDeleteAndMoveKeepTheEntireSourceFolderChain() throws {
        _ = try repository.createFolder(named: "来源")
        _ = try repository.createFolder(named: "子目录", in: "来源")
        _ = try repository.createFolder(named: "目标")
        let imported = try repository.importFile(from: source("clip.mp4"), into: "来源/子目录")
        let index = root.appendingPathComponent(".playit-index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try repository.delete(items: [imported]))
        XCTAssertEqual(try Data(contentsOf: repository.url(for: imported)), Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try repository.move(items: [imported], to: "目标"))
        XCTAssertEqual(try Data(contentsOf: repository.url(for: imported)), Data([1, 2, 3, 4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("来源/子目录").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("目标").path).isEmpty)
    }

    func testCommittedDeleteSucceedsWhenEmptyFolderCleanupIsDenied() throws {
        _ = try repository.createFolder(named: "protected")
        _ = try repository.createFolder(named: "child", in: "protected")
        let imported = try repository.importFile(from: source("clip.mp4"), into: "protected/child")
        let protected = root.appendingPathComponent("protected")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protected.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protected.path) }
        guard !FileManager.default.isWritableFile(atPath: protected.path) else {
            throw XCTSkip("Directory permission restrictions are not enforced for this test user")
        }

        try repository.delete(items: [imported])

        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url(for: imported).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("protected/child").path))
        XCTAssertTrue(try repository.scan().isEmpty)
        XCTAssertTrue(try repository.cleanupEmptyFolders().isEmpty)
    }

    func testStartupCleanupRemovesOldEmptyTreesAndRetainsHiddenOrLinkedContents() throws {
        _ = try repository.createFolder(named: "old")
        _ = try repository.createFolder(named: "child", in: "old")
        _ = try repository.createFolder(named: "leaf", in: "old/child")
        _ = try repository.createFolder(named: "standalone")
        _ = try repository.createFolder(named: "blocked")
        try Data([9]).write(to: root.appendingPathComponent("blocked/.keep"))
        let hidden = root.appendingPathComponent(".playit-incoming/internal-empty")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let outside = sources.appendingPathComponent("external-empty")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: outside)
        _ = try repository.createFolder(named: "with-link")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("with-link/shortcut"), withDestinationURL: outside)

        let removed = try repository.cleanupEmptyFolders()

        XCTAssertEqual(removed, ["old/child/leaf", "old/child", "old", "standalone"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside-link").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("with-link/shortcut").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("blocked/.keep")), Data([9]))
        XCTAssertTrue(try repository.cleanupEmptyFolders().isEmpty)
    }

    func testStartupCleanupDoesNotMakeLaterFolderCreationOrScanningDestructive() throws {
        XCTAssertTrue(try repository.cleanupEmptyFolders().isEmpty)
        _ = try repository.createFolder(named: "待导入")
        _ = try repository.createFolder(named: "片段", in: "待导入")
        XCTAssertTrue(try repository.scan().isEmpty)
        XCTAssertEqual(try repository.folders(in: "待导入").map(\.path), ["待导入/片段"])
        XCTAssertTrue(try repository.move(items: [], to: "待导入/片段").isEmpty)

        let imported = try repository.importFile(from: source("clip.mp4"), into: "待导入/片段")

        XCTAssertEqual(imported.relativePath, "待导入/片段/clip.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url(for: imported).path))
    }

    func testDeleteFolderRemovesWholeTreeAndOnlyItsCatalogEntries() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "海边", in: "旅行")
        _ = try repository.createFolder(named: "旅行2")
        _ = try repository.importFile(from: source("nested.mp4"), into: "旅行/海边")
        _ = try repository.importFile(from: source("image.jpg"), into: "旅行")
        let retained = try repository.importFile(from: source("keep.mp4"), into: "旅行2")
        try repository.setMetadata(for: retained, duration: 12, pixelWidth: 640, pixelHeight: 360)
        try Data("notes".utf8).write(to: root.appendingPathComponent("旅行/readme.txt"))

        try repository.deleteFolder(at: "旅行")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("旅行").path))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".playit-index.json"))) as? [String: Any])
        XCTAssertEqual(Set(index.keys), [retained.relativePath])
        let reloaded = MediaLibraryRepository(rootURL: root)
        let result = try XCTUnwrap(reloaded.scan().first)
        XCTAssertEqual(result.relativePath, retained.relativePath)
        XCTAssertEqual(result.duration, 12)
        XCTAssertEqual(try reloaded.folders().map(\.path), ["旅行2"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".playit-delete-") })
    }

    func testDeleteFolderRejectsRootTraversalHiddenAndNonDirectoryPaths() throws {
        _ = try repository.createFolder(named: "保留")
        let media = try repository.importFile(from: source("keep.mp4"))
        for path in ["", "/", ".", "..", "../Sources", "保留/..", "保留/", "保留//child", ".playit-index.json", media.relativePath, "missing", root.path] {
            XCTAssertThrowsError(try repository.deleteFolder(at: path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("保留").path))
        XCTAssertEqual(try repository.scan().map(\.id), [media.id])
    }

    func testDeleteFolderRejectsSymbolicLinkTargetAndAncestor() throws {
        _ = try repository.createFolder(named: "保留")
        _ = try repository.createFolder(named: "child", in: "保留")
        let external = try source("outside.mp4")
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("child"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external-link"), withDestinationURL: sources)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside-link"), withDestinationURL: root.appendingPathComponent("保留"))
        for path in ["external-link", "external-link/child", "inside-link", "inside-link/child"] {
            XCTAssertThrowsError(try repository.deleteFolder(at: path), path)
        }
        XCTAssertEqual(try Data(contentsOf: external), Data([1, 2, 3, 4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("保留/child").path))
    }

    func testDeleteFolderDoesNotFollowItsDescendantSymbolicLinks() throws {
        _ = try repository.createFolder(named: "移除")
        let external = try source("outside.mp4")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("移除/shortcut"), withDestinationURL: sources)

        try repository.deleteFolder(at: "移除")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("移除").path))
        XCTAssertEqual(try Data(contentsOf: external), Data([1, 2, 3, 4]))
    }

    func testDeleteFolderRestoresTreeWhenCatalogCommitFails() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "海边", in: "旅行")
        let media = try repository.importFile(from: source("clip.mp4"), into: "旅行/海边")
        let index = root.appendingPathComponent(".playit-index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try repository.deleteFolder(at: "旅行"))

        XCTAssertEqual(try Data(contentsOf: repository.url(for: media)), Data([1, 2, 3, 4]))
        XCTAssertEqual(try repository.folders().map(\.path), ["旅行"])
        XCTAssertEqual(try repository.scan().map(\.id), [media.id])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".playit-delete-") })
    }

    func testDeleteSelectionRemovesFoldersAndFilesTogether() throws {
        for (name, parent) in [("旅行", nil), ("海边", "旅行"), ("工作", nil), ("保留", nil)] as [(String, String?)] {
            _ = try repository.createFolder(named: name, in: parent)
        }
        let nested = try repository.importFile(from: source("clip.mp4"), into: "旅行/海边")
        _ = try repository.importFile(from: source("doc.jpg"), into: "工作")
        let kept = try repository.importFile(from: source("keep.mp4"), into: "保留")
        let loose = try repository.importFile(from: source("loose.mp4"))
        let remaining = try repository.importFile(from: source("remaining.png"))
        try repository.setMetadata(for: kept, duration: 7, pixelWidth: 640, pixelHeight: 360)

        // A nested folder, a file inside a selected folder and a repeated file
        // are all part of the same selection rather than separate failures.
        try repository.delete(folders: ["旅行", "旅行/海边", "工作"], items: [loose, nested, loose])

        for path in ["旅行", "工作", loose.relativePath] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(try repository.folders().map(\.path), ["保留"])
        XCTAssertEqual(Set(try repository.scan().map(\.id)), [kept.id, remaining.id])
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".playit-index.json"))) as? [String: Any])
        XCTAssertEqual(Set(index.keys), [kept.relativePath, remaining.relativePath])
        XCTAssertEqual(try MediaLibraryRepository(rootURL: root).scan().first { $0.id == kept.id }?.duration, 7)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".playit-delete-") })
    }

    func testDeleteSelectionValidatesEverythingBeforeRemovingAnything() throws {
        _ = try repository.createFolder(named: "旅行")
        let media = try repository.importFile(from: source("clip.mp4"), into: "旅行")
        let loose = try repository.importFile(from: source("loose.mp4"))
        let missing = MediaItem(relativePath: "gone.mp4", kind: .video)
        let attempts: [([String], [MediaItem])] = [
            (["旅行", "missing"], [loose]),
            (["旅行"], [loose, missing]),
            (["旅行", ""], []),
            (["旅行", "../Sources"], []),
            (["旅行", loose.relativePath], [])
        ]
        for (folders, items) in attempts {
            XCTAssertThrowsError(try repository.delete(folders: folders, items: items), "\(folders)")
        }
        XCTAssertEqual(try Data(contentsOf: repository.url(for: media)), Data([1, 2, 3, 4]))
        XCTAssertEqual(Set(try repository.scan().map(\.id)), [media.id, loose.id])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".playit-delete-") })
    }

    func testDeleteSelectionRestoresEverythingWhenCatalogCommitFails() throws {
        _ = try repository.createFolder(named: "旅行")
        _ = try repository.createFolder(named: "工作")
        let first = try repository.importFile(from: source("clip.mp4"), into: "旅行")
        let second = try repository.importFile(from: source("doc.jpg"), into: "工作")
        let loose = try repository.importFile(from: source("loose.mp4"))
        let index = root.appendingPathComponent(".playit-index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try repository.delete(folders: ["旅行", "工作"], items: [loose]))

        for item in [first, second, loose] {
            XCTAssertEqual(try Data(contentsOf: repository.url(for: item)), Data([1, 2, 3, 4]), item.relativePath)
        }
        XCTAssertEqual(Set(try repository.folders().map(\.path)), ["工作", "旅行"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".playit-delete-") })
    }

    func testDeleteSelectionPrunesTheFolderItEmptiesAndIgnoresAnEmptySelection() throws {
        _ = try repository.createFolder(named: "上级")
        _ = try repository.createFolder(named: "A", in: "上级")
        _ = try repository.createFolder(named: "B", in: "上级")
        _ = try repository.createFolder(named: "旁边")

        try repository.delete(folders: [], items: [])
        XCTAssertEqual(Set(try repository.folders().map(\.path)), ["上级", "旁边"])

        try repository.delete(folders: ["上级/A", "上级/B"], items: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("上级").path))
        XCTAssertEqual(try repository.folders().map(\.path), ["旁边"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testCorruptCatalogDoesNotHideMedia() throws {
        _ = try repository.importFile(from: source("clip.mp4"))
        try Data("not-json".utf8).write(to: root.appendingPathComponent(".playit-index.json"))
        let reloaded = MediaLibraryRepository(rootURL: root)
        XCTAssertEqual(try reloaded.scan().map(\.filename), ["clip.mp4"])
    }

    func testUnreadableOrUnwritableCatalogDoesNotHideExistingMedia() throws {
        _ = try repository.importFile(from: source("clip.mp4"))
        let indexURL = root.appendingPathComponent(".playit-index.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        let reloaded = MediaLibraryRepository(rootURL: root)
        XCTAssertEqual(try reloaded.scan().map(\.filename), ["clip.mp4"])
    }

    func testOnlyCommittedDeleteStagingIsCleanedOnReopen() throws {
        _ = try repository.scan()
        let committed = root.appendingPathComponent(".playit-delete-" + UUID().uuidString)
        let uncommitted = root.appendingPathComponent(".playit-delete-" + UUID().uuidString)
        for directory in [committed, uncommitted] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([1]).write(to: directory.appendingPathComponent("0"))
        }
        try Data().write(to: committed.appendingPathComponent(".committed"))
        let reloaded = MediaLibraryRepository(rootURL: root)
        XCTAssertTrue(try reloaded.scan().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uncommitted.appendingPathComponent("0").path))
    }

    func testConcurrentDuplicateImportsNeverOverwriteEachOther() throws {
        let input = try source("clip.mp4")
        let errorsLock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { _ = try repository.importFile(from: input) }
            catch {
                errorsLock.lock()
                failures.append(String(describing: error))
                errorsLock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let result = try repository.scan()
        XCTAssertEqual(result.count, 12)
        XCTAssertEqual(Set(result.map(\.filename)).count, 12)
        XCTAssertTrue(try result.allSatisfy { try Data(contentsOf: repository.url(for: $0)) == Data([1, 2, 3, 4]) })
    }
}
