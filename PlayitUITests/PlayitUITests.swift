import XCTest

final class PlayitUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-prism-sample-media"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.navigationBars["Prism"].waitForExistence(timeout: 15))
    }

    func testGlobalMediaFiltersAndSearch() {
        app.buttons["所有图片"].tap()
        XCTAssertTrue(app.buttons["media.sample-still.png"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["media.sample-motion.mp4"].exists)
        app.buttons["所有视频"].tap()
        let search = searchField
        search.tap()
        search.typeText("sample-variable")
        XCTAssertTrue(app.buttons["media.sample-variable.mkv"].waitForExistence(timeout: 5))
        let absent = NSPredicate(format: "exists == false")
        expectation(for: absent, evaluatedWith: app.buttons["media.sample-motion.mp4"])
        waitForExpectations(timeout: 5)
    }

    func testBrandMarkOpensAboutAndPhotoViewerOpensFromGrid() {
        let brand = app.buttons["library.brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5))
        brand.tap()
        XCTAssertTrue(app.buttons["about.done"].waitForExistence(timeout: 5))
        app.buttons["about.done"].tap()

        app.buttons["所有图片"].tap()
        let photo = app.buttons["media.sample-still.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let close = app.buttons["photo.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 / 1"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
    }

    func testEmptyFolderDeletionCanBeCancelledAndConfirmed() {
        let name = "UITest-Delete-" + UUID().uuidString
        app.buttons["文件夹"].tap()
        createEmptyFolder(named: name)
        let folder = app.buttons["folder.\(name)"]

        app.buttons["folder.options.\(name)"].tap()
        app.buttons["folder.delete.\(name)"].tap()
        XCTAssertTrue(app.buttons["folder.confirmDelete"].waitForExistence(timeout: 5))
        app.buttons["folder.cancelDelete"].tap()
        XCTAssertTrue(folder.exists, "Cancelling deletion must preserve the empty folder.")
        XCTAssertFalse(app.buttons["folder.confirmDelete"].exists)

        app.buttons["folder.options.\(name)"].tap()
        app.buttons["folder.delete.\(name)"].tap()
        XCTAssertTrue(app.buttons["folder.confirmDelete"].waitForExistence(timeout: 5))
        app.buttons["folder.confirmDelete"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: folder)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.alerts["操作未完成"].exists)

        // Recreating the same path checks that confirmation removed the actual
        // directory, rather than only filtering its row out of the visible list.
        createEmptyFolder(named: name)
        folder.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["文件夹是空的"].waitForExistence(timeout: 10))
        app.buttons["library.import"].tap()
        app.buttons["folder.deleteCurrent"].tap()
        XCTAssertTrue(app.buttons["folder.confirmDelete"].waitForExistence(timeout: 5))
        app.buttons["folder.confirmDelete"].tap()
        XCTAssertTrue(app.navigationBars["Prism"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: folder)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.navigationBars[name].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testSelectionModeSelectsFoldersAndSelectAllDeletesThem() {
        let parent = "UITest-Select-" + UUID().uuidString
        app.buttons["文件夹"].tap()
        createEmptyFolder(named: parent)
        app.buttons["folder.\(parent)"].tap()
        XCTAssertTrue(app.navigationBars[parent].waitForExistence(timeout: 5))
        createEmptyFolder(named: "A", in: parent)
        createEmptyFolder(named: "B", in: parent)

        // A page holding only folders can enter selection mode, and a tap marks
        // a folder instead of opening it.
        let select = app.buttons["library.select"]
        XCTAssertTrue(select.isEnabled)
        select.tap()
        let first = app.buttons["folder.\(parent)/A"]
        first.tap()
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[parent].exists)
        XCTAssertTrue(first.isSelected)
        first.tap()
        XCTAssertTrue(app.staticTexts["已选 0 项"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["selection.delete"].isEnabled)

        app.buttons["selection.all"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["selection.move"].isEnabled, "Folders cannot be moved.")
        app.buttons["selection.delete"].tap()
        let confirm = app.buttons["selection.confirmDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Removing both subfolders empties the parent, which is cleaned up like
        // after any other deletion, so the browser returns to the library root.
        XCTAssertTrue(app.navigationBars["Prism"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["folder.\(parent)"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testDeletingLastVideoAutomaticallyRemovesFolderAndReturnsToParent() {
        let name = "UITest-AutoPrune-" + UUID().uuidString
        let filename = "sample-legacy.avi"
        app.buttons["文件夹"].tap()
        createEmptyFolder(named: name)

        app.buttons["所有视频"].tap()
        let search = searchField
        search.tap()
        search.typeText(filename)
        let sourceOptions = app.buttons["file.options.\(filename)"]
        XCTAssertTrue(sourceOptions.waitForExistence(timeout: 10))
        sourceOptions.tap()
        app.buttons["file.move.\(filename)"].tap()
        let destination = app.buttons["move.destination.\(name)"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()

        let clearSearch = app.buttons["清除搜索"].firstMatch
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: clearSearch)
        waitForExpectations(timeout: 10)
        clearSearch.tap()
        app.buttons["文件夹"].tap()
        let folder = app.buttons["folder.\(name)"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))

        // Moving a bundled sample into a newly created directory gives this
        // test a real, uniquely owned source folder with exactly one video.
        let path = name + "/" + filename
        let insideOptions = app.buttons["file.options.\(path)"]
        XCTAssertTrue(insideOptions.waitForExistence(timeout: 10))
        insideOptions.tap()
        app.buttons["file.delete.\(path)"].tap()
        let confirmation = app.buttons["file.confirmDelete"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()

        XCTAssertTrue(app.navigationBars["Prism"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: folder)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.navigationBars[name].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testAccurateFrameStepAndScrubKeepsPausedState() {
        openVideo("sample-motion.mp4")
        let next = app.buttons["player.nextFrame"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 20)
        let playPause = app.buttons["player.playPause"]
        if playPause.label == "暂停" { playPause.tap() }
        XCTAssertEqual(playPause.label, "播放")
        let clock = app.staticTexts["player.currentTime"]
        let before = clock.label
        next.tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: clock)
        waitForExpectations(timeout: 5)
        let timeline = app.descendants(matching: .any)["player.timeline"]
        XCTAssertTrue(timeline.exists)
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        expectation(for: NSPredicate { _, _ in
            self.seconds(clock.label) > 2 && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        app.buttons["player.previousFrame"].tap()
        XCTAssertEqual(playPause.label, "播放")
    }

    func testUSBTransferInstructionsAreReachable() {
        app.tabBars.buttons["传文件"].tap()
        app.buttons["transfer.usbHelp"].tap()
        XCTAssertTrue(app.navigationBars["USB 传文件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mac"].exists)
        XCTAssertTrue(app.staticTexts["Windows"].exists)
    }

    func testImportEntryPointsAreNotDuplicated() {
        app.buttons["文件夹"].tap()
        let name = "UITest-Import-" + UUID().uuidString
        createEmptyFolder(named: name)
        app.buttons["folder.\(name)"].tap()
        XCTAssertTrue(app.staticTexts["文件夹是空的"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library.import").count, 1)
        XCTAssertFalse(app.buttons["导入文件"].exists)
        XCTAssertFalse(app.buttons["从电脑传入"].exists)

        app.tabBars.buttons["传文件"].tap()
        XCTAssertTrue(app.buttons["transfer.fileImport"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "transfer.fileImport").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "transfer.usbHelp").count, 1)
        XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "从文件导入").count, 0)
    }

    func testPinchZoomAndResetKeepPausedVideo() {
        openVideo("sample-motion.mp4")
        app.buttons["player.nextFrame"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        let video = app.descendants(matching: .any)["player.video"]
        video.pinch(withScale: 2.5, velocity: 2)
        expectation(for: NSPredicate { _, _ in
            (video.value as? String)?.contains("已放大") == true
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(playPause.label, "播放")
        let reset = app.buttons["player.resetZoom"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        expectation(for: NSPredicate { _, _ in
            (video.value as? String)?.contains("完整画面") == true
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(playPause.label, "播放")
    }

    func testScreenSwipeSeeksBothWaysAndPreservesPause() {
        openVideo("sample-motion.mp4")
        app.buttons["player.nextFrame"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        let clock = app.staticTexts["player.currentTime"]
        let before = seconds(clock.label)
        let video = app.descendants(matching: .any)["player.video"]
        let start = video.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.43))
        let end = video.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.43))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: NSPredicate { _, _ in
            self.seconds(clock.label) > before + 0.3 && playPause.isEnabled && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        let advanced = seconds(clock.label)
        end.press(forDuration: 0.05, thenDragTo: start)
        expectation(for: NSPredicate { _, _ in
            self.seconds(clock.label) < advanced - 0.3 && playPause.isEnabled && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.staticTexts["player.fastPlayback"].exists)
        XCTAssertTrue((video.value as? String)?.contains("完整画面") == true)
    }

    func testSlowDiagonalDragAndHoldTransitionKeepPausedState() {
        openVideo("sample-motion.mp4")
        app.buttons["player.nextFrame"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        let clock = app.staticTexts["player.currentTime"]
        let before = seconds(clock.label)
        let video = app.descendants(matching: .any)["player.video"]
        let start = video.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.42))
        let end = video.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.46))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        expectation(for: NSPredicate { _, _ in
            self.seconds(clock.label) > before + 0.5 && playPause.isEnabled && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        let advanced = seconds(clock.label)
        // Begin as a stationary 2× hold, then move left. Seeking must take over
        // the same touch and restore the original paused state on finger-up.
        end.press(forDuration: 0.55, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0)
        expectation(for: NSPredicate { _, _ in
            self.seconds(clock.label) < advanced - 0.2 && playPause.isEnabled && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.staticTexts["player.fastPlayback"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["player.screenSeekPreview"].exists)
    }

    func testScreenSwipeRestoresPlayingStateWithHiddenControls() {
        openVideo("sample-motion.mp4")
        enableLooping()
        let playPause = app.buttons["player.playPause"]
        if playPause.label == "播放" { playPause.tap() }
        let close = app.buttons["player.close"]
        expectation(for: NSPredicate { _, _ in !close.isHittable }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        let video = app.descendants(matching: .any)["player.video"]
        let start = video.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.43))
        let end = video.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.43))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: NSPredicate { _, _ in
            playPause.isEnabled && playPause.label == "暂停" && close.isHittable
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.descendants(matching: .any)["player.screenSeekPreview"].exists)
        XCTAssertFalse(app.staticTexts["player.fastPlayback"].exists)
    }

    func testGestureGuideOpensFromOptionsAndReturnsToPausedVideo() {
        openVideo("sample-motion.mp4")
        app.buttons["player.nextFrame"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        app.buttons["player.options"].tap()
        let entry = app.buttons["player.openGestureGuide"]
        revealInOptions(entry)
        entry.tap()
        XCTAssertTrue(app.navigationBars["操作手势"].waitForExistence(timeout: 5))
        let guide = app.scrollViews["player.gestureGuide.scroll"]
        XCTAssertTrue(guide.exists)
        app.buttons["player.gestureGuide.done"].tap()
        expectation(for: NSPredicate { _, _ in
            playPause.isHittable && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.navigationBars["操作手势"].exists)
        XCTAssertTrue(app.buttons["player.nextFrame"].isEnabled)
    }

    func testLongPressTemporarilyPlaysThenRestoresPauseAndRate() {
        openVideo("sample-motion.mp4")
        let next = app.buttons["player.nextFrame"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 20)
        next.tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        let clock = app.staticTexts["player.currentTime"]
        let before = seconds(clock.label)
        let video = app.descendants(matching: .any)["player.video"]
        XCTAssertTrue(video.exists)
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.9)
        expectation(for: NSPredicate { _, _ in
            self.seconds(clock.label) > before + 0.2 && playPause.label == "播放"
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["player.fastPlayback"].exists)
        XCTAssertEqual(app.buttons["player.rate"].value as? String, "1×")
    }

    func testPortraitVideoFillsUprightScreenWithoutRotateButton() {
        assertPortraitPlayback(filename: "sample-portrait.mov")
    }

    func testLandscapeVideoRotatesToLandscapeAndBack() {
        assertLandscapeRotation(filename: "sample-motion.mp4")
    }

    func testRotatedLandscapeEncodingStaysPortrait() {
        assertPortraitPlayback(filename: "sample-rotated.mov")
    }

    func testPlayingControlsAutoHideAndVideoTapRestoresThem() {
        openVideo("sample-motion.mp4")
        enableLooping()
        let playPause = app.buttons["player.playPause"]
        if playPause.label == "播放" { playPause.tap() }
        let close = app.buttons["player.close"]
        expectation(for: NSPredicate { _, _ in !close.isHittable }, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        let video = app.descendants(matching: .any)["player.video"]
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate { _, _ in close.isHittable }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(playPause.label, "暂停")
    }

    func testPausedControlsRemainVisibleBeyondAutoHideDelay() {
        openVideo("sample-motion.mp4")
        app.buttons["player.nextFrame"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        let close = app.buttons["player.close"]
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !close.isHittable }, object: nil)
        hidden.isInverted = true
        wait(for: [hidden], timeout: 3.5)
        XCTAssertTrue(app.buttons["player.nextFrame"].isHittable)
    }

    func testCurrentListSwitchesVideosAndKeepsSearch() {
        let search = searchField
        search.tap()
        search.typeText("sample-")
        let motion = app.buttons["media.sample-motion.mp4"]
        XCTAssertTrue(motion.waitForExistence(timeout: 10))
        motion.tap()
        XCTAssertTrue(app.buttons["player.options"].waitForExistence(timeout: 10))
        app.buttons["player.options"].tap()
        app.buttons["player.queue"].tap()
        XCTAssertTrue(app.navigationBars["当前列表"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["player.queue.sample-still.png"].exists)
        app.buttons["player.queue.sample-portrait.mov"].tap()
        let filename = app.staticTexts["player.filename"]
        expectation(for: NSPredicate(format: "label == %@", "sample-portrait"), evaluatedWith: filename)
        waitForExpectations(timeout: 15)
        app.buttons["player.close"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "sample-")
    }

    func testCaptureFrameOpensSaveActionsAndReturnsToPausedVideo() {
        openVideo("sample-motion.mp4")
        app.buttons["player.options"].tap()
        let capture = app.buttons["player.captureFrame"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        capture.tap()
        XCTAssertTrue(app.buttons["player.frame.saveFiles"].waitForExistence(timeout: 15))
        app.buttons["player.frame.done"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
    }

    func testRateChipChangesSpeedInPlace() {
        openVideo("sample-motion.mp4")
        let rate = app.buttons["player.rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 5))
        XCTAssertEqual(rate.value as? String, "1×")
        rate.tap()
        let faster = app.buttons["player.rate.1.5×"]
        XCTAssertTrue(faster.waitForExistence(timeout: 5))
        faster.tap()
        expectation(for: NSPredicate(format: "value == %@", "1.5×"), evaluatedWith: rate)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: faster)
        waitForExpectations(timeout: 5)
    }

    func testABEditorSetsAnIntervalWithoutReopeningTheSheet() {
        openVideo("sample-motion.mp4")
        app.buttons["player.nextFrame"].tap()
        let playPause = app.buttons["player.playPause"]
        expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: playPause)
        waitForExpectations(timeout: 5)
        app.buttons["player.options"].tap()
        let entry = app.buttons["player.abLoop"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let pointA = app.buttons["player.loopStart"]
        XCTAssertTrue(pointA.waitForExistence(timeout: 5))
        pointA.tap()
        let timeline = app.descendants(matching: .any)["player.timeline"]
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let pointB = app.buttons["player.loopEnd"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: pointB)
        waitForExpectations(timeout: 10)
        pointB.tap()
        expectation(for: NSPredicate { _, _ in (pointB.value as? String)?.contains(":") == true }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.buttons["player.abDone"].tap()
        XCTAssertFalse(app.buttons["player.loopStart"].exists)
    }

    func testVerticalSwipeSwitchesVideosInTheCurrentList() {
        let search = searchField
        search.tap()
        search.typeText("sample-")
        let motion = app.buttons["media.sample-motion.mp4"]
        XCTAssertTrue(motion.waitForExistence(timeout: 10))
        motion.tap()
        let ready = app.buttons["player.nextFrame"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 20)
        let filename = app.staticTexts["player.filename"]
        let first = filename.label
        let video = app.descendants(matching: .any)["player.video"]
        video.swipeUp()
        if app.staticTexts["player.notice"].waitForExistence(timeout: 2) {
            // The opened clip was the last one; go the other way.
            video.swipeDown()
        }
        expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: filename)
        waitForExpectations(timeout: 15)
    }

    private var searchField: XCUIElement { app.searchFields.firstMatch }

    private func enableLooping() {
        app.buttons["player.options"].tap()
        let endAction = app.buttons["player.endAction"]
        XCTAssertTrue(endAction.waitForExistence(timeout: 5))
        endAction.tap()
        let loop = app.buttons["单条循环"]
        XCTAssertTrue(loop.waitForExistence(timeout: 5))
        loop.tap()
        app.buttons["player.settingsDone"].tap()
    }

    /// Form rows load lazily; expand or scroll the sheet until the row exists.
    private func revealInOptions(_ element: XCUIElement) {
        var attempts = 0
        while !element.waitForExistence(timeout: 1.5) && attempts < 4 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.exists)
    }

    private func createEmptyFolder(named name: String, in parent: String? = nil) {
        app.buttons["library.import"].tap()
        app.buttons["folder.new"].tap()
        let prompt = app.alerts["新建文件夹"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let field = prompt.textFields["folder.nameInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        prompt.buttons["folder.create"].tap()
        let path = parent.map { $0 + "/" + name } ?? name
        XCTAssertTrue(app.buttons["folder.\(path)"].waitForExistence(timeout: 10))
    }

    private func openVideo(_ filename: String) {
        let search = searchField
        search.tap()
        search.typeText(filename)
        let row = app.buttons["media.\(filename)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let ready = app.buttons["player.nextFrame"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 20)
    }

    private func assertPortraitPlayback(filename: String) {
        openVideo(filename)
        let video = app.descendants(matching: .any)["player.video"]
        expectation(for: NSPredicate { _, _ in
            let frame = self.app.frame
            return frame.height > frame.width && video.frame.height > frame.height * 0.7
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["player.fullscreenToggle"].exists,
                       "Portrait and rotated-portrait videos already fill an upright phone.")
    }

    private func assertLandscapeRotation(filename: String) {
        openVideo(filename)
        let toggle = app.buttons["player.fullscreenToggle"]
        if app.horizontalSizeClass == .regular {
            XCTAssertFalse(toggle.waitForExistence(timeout: 2),
                           "Wide screens (iPad, an unfolded iPhone Duo) already give landscape video room.")
            return
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let fullscreen = app.descendants(matching: .any)["player.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        let video = app.descendants(matching: .any)["player.video"]
        expectation(for: NSPredicate { _, _ in
            let frame = self.app.frame
            return frame.width > frame.height && video.frame.height > frame.height * 0.7
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        if !app.buttons["player.fullscreenToggle"].isHittable {
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        app.buttons["player.fullscreenToggle"].tap()
        expectation(for: NSPredicate { _, _ in self.app.frame.height > self.app.frame.width }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.descendants(matching: .any)["player.fullscreen"].exists)
    }

    private func seconds(_ value: String) -> Double {
        value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
