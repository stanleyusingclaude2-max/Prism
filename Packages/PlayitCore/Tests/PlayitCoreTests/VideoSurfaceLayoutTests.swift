import XCTest
@testable import PlayitCore

final class VideoSurfaceLayoutTests: XCTestCase {
    func testLandscapeVideoInLandscapeViewportHasCompleteCenteredImage() throws {
        let layout = try layout(width: 852, height: 393, videoWidth: 1920, videoHeight: 1080)
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.x, 76.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(image.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(image.width, 698.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(image.height, 393, accuracy: 0.000_001)
        XCTAssertLessThan(layout.layerFrame.y, 0) // Cropped square margins contain no video.
        try assertDecoderImageMapsExactly(layout, viewportWidth: 852, viewportHeight: 393,
                                         videoWidth: 1920, videoHeight: 1080)
    }

    func testPortraitVideoInPortraitViewportHasCompleteCenteredImage() throws {
        let layout = try layout(width: 393, height: 852, videoWidth: 1080, videoHeight: 1920)
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(image.y, 76.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(image.width, 393, accuracy: 0.000_001)
        XCTAssertEqual(image.height, 698.666_666_666_7, accuracy: 0.000_001)
        XCTAssertLessThan(layout.layerFrame.x, 0)
        try assertDecoderImageMapsExactly(layout, viewportWidth: 393, viewportHeight: 852,
                                         videoWidth: 1080, videoHeight: 1920)
    }

    func testLandscapeVideoInPortraitViewportDoesNotStretch() throws {
        let layout = try layout(width: 393, height: 852, videoWidth: 1920, videoHeight: 1080)
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.width, 393, accuracy: 0.000_001)
        XCTAssertEqual(image.height, 221.0625, accuracy: 0.000_001)
        XCTAssertEqual(image.y, 315.46875, accuracy: 0.000_001)
        try assertDecoderImageMapsExactly(layout, viewportWidth: 393, viewportHeight: 852,
                                         videoWidth: 1920, videoHeight: 1080)
    }

    func testPortraitVideoInLandscapeViewportDoesNotStretch() throws {
        let layout = try layout(width: 852, height: 393, videoWidth: 1080, videoHeight: 1920)
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.width, 221.0625, accuracy: 0.000_001)
        XCTAssertEqual(image.height, 393, accuracy: 0.000_001)
        XCTAssertEqual(image.x, 315.46875, accuracy: 0.000_001)
        try assertDecoderImageMapsExactly(layout, viewportWidth: 852, viewportHeight: 393,
                                         videoWidth: 1080, videoHeight: 1920)
    }

    func testSquareVideoRemainsSquareInEveryViewport() throws {
        for viewport in [(393.0, 852.0), (852.0, 393.0), (1024.0, 768.0)] {
            let layout = try layout(width: viewport.0, height: viewport.1, videoWidth: 1080, videoHeight: 1080)
            let image = try XCTUnwrap(layout.videoFrame)
            XCTAssertEqual(image.width, image.height, accuracy: 0.000_001)
            try assertDecoderImageMapsExactly(layout, viewportWidth: viewport.0, viewportHeight: viewport.1,
                                             videoWidth: 1080, videoHeight: 1080)
        }
    }

    func testRotatedPhoneVideoUsesItsActualPortraitShape() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1920, height: 1080, rotationDegrees: 90))
        let layout = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 393, viewportHeight: 852, geometry: geometry))
        try assertDecoderImageMapsExactly(layout, viewportWidth: 393, viewportHeight: 852,
                                         videoWidth: 1080, videoHeight: 1920)
    }

    func testUnknownMetadataIsContainedAndCanBeResolvedWithoutChangingTargetShape() throws {
        let pending = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 393, viewportHeight: 852, geometry: nil))
        XCTAssertNil(pending.videoFrame)
        XCTAssertEqual(pending.layerFrame.width, 393)
        XCTAssertEqual(pending.layerFrame.height, 393)
        XCTAssertEqual(pending.layerFrame.x, 0)
        XCTAssertEqual(pending.layerFrame.y, 229.5)
        let ready = try layout(width: 393, height: 852, videoWidth: 1080, videoHeight: 1920)
        XCTAssertEqual(ready.layerFrame.width, ready.layerFrame.height)
    }

    func testInvalidViewportsAreRejected() {
        for invalid in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(VideoSurfaceLayout(viewportWidth: invalid, viewportHeight: 852, geometry: nil))
            XCTAssertNil(VideoSurfaceLayout(viewportWidth: 393, viewportHeight: invalid, geometry: nil))
        }
    }

    func testNaturalMetalExtentStaysAtFixedTargetAcrossViewports() throws {
        for viewport in [(393.0, 852.0), (852.0, 393.0), (430.0, 932.0), (932.0, 430.0), (1024.0, 768.0)] {
            for video in [(1920.0, 1080.0), (1080.0, 1920.0), (1080.0, 1080.0)] {
                for zoom in [1.0, 2.0] {
                    let layout = try layout(width: viewport.0, height: viewport.1,
                                            videoWidth: video.0, videoHeight: video.1, zoom: zoom)
                    let scale = try XCTUnwrap(layout.contentsScale(forDrawableSide: 2048))
                    let naturalWidth = layout.layerFrame.width * scale
                    let naturalHeight = layout.layerFrame.height * scale
                    XCTAssertEqual(naturalWidth, 2048, accuracy: 0.000_001)
                    XCTAssertEqual(naturalHeight, 2048, accuracy: 0.000_001)
                    // MoltenVK converts these dimensions to integer VkExtent2D.
                    XCTAssertEqual(Int(naturalWidth), 2048)
                    XCTAssertEqual(Int(naturalHeight), 2048)
                }
            }
        }
    }

    func testInvalidDrawableTargetIsRejected() throws {
        let layout = try layout(width: 393, height: 852, videoWidth: 1920, videoHeight: 1080)
        for target in [Double.nan, .infinity, 0, -1] {
            XCTAssertNil(layout.contentsScale(forDrawableSide: target))
        }
    }

    func testTwoTimesZoomMagnifiesLandscapeImageAroundViewportCenter() throws {
        let layout = try layout(width: 852, height: 393, videoWidth: 1920, videoHeight: 1080, zoom: 2)
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.width, 1397.333_333_333_3, accuracy: 0.000_001)
        XCTAssertEqual(image.height, 786, accuracy: 0.000_001)
        XCTAssertEqual(image.x, -272.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(image.y, -196.5, accuracy: 0.000_001)
        try assertDecoderImageMapsExactly(layout, viewportWidth: 852, viewportHeight: 393,
                                         videoWidth: 1920, videoHeight: 1080, contained: false)
    }

    func testTwoTimesZoomMagnifiesPortraitImageWithoutStretching() throws {
        let layout = try layout(width: 393, height: 852, videoWidth: 1080, videoHeight: 1920, zoom: 2)
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.width, 786, accuracy: 0.000_001)
        XCTAssertEqual(image.height, 1397.333_333_333_3, accuracy: 0.000_001)
        XCTAssertEqual(image.x, -196.5, accuracy: 0.000_001)
        XCTAssertEqual(image.y, -272.666_666_666_7, accuracy: 0.000_001)
        try assertDecoderImageMapsExactly(layout, viewportWidth: 393, viewportHeight: 852,
                                         videoWidth: 1080, videoHeight: 1920, contained: false)
    }

    func testZoomMaintainsTheCompleteImageMappingInOppositeOrientations() throws {
        for viewport in [(393.0, 852.0), (852.0, 393.0)] {
            for video in [(1920.0, 1080.0), (1080.0, 1920.0), (1080.0, 1080.0)] {
                let layout = try layout(width: viewport.0, height: viewport.1,
                                        videoWidth: video.0, videoHeight: video.1, zoom: 2)
                try assertDecoderImageMapsExactly(layout, viewportWidth: viewport.0, viewportHeight: viewport.1,
                                                 videoWidth: video.0, videoHeight: video.1, contained: false)
            }
        }
    }

    func testZoomUsesRotatedDisplayShape() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1920, height: 1080, rotationDegrees: 270))
        let layout = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 393, viewportHeight: 852,
                                                    geometry: geometry, zoomScale: 2))
        try assertDecoderImageMapsExactly(layout, viewportWidth: 393, viewportHeight: 852,
                                         videoWidth: 1080, videoHeight: 1920, contained: false)
    }

    func testUnknownMetadataStaysContainedEvenIfZoomWasRequested() throws {
        let layout = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 393, viewportHeight: 852,
                                                    geometry: nil, zoomScale: 2))
        XCTAssertNil(layout.videoFrame)
        XCTAssertEqual(layout.layerFrame.width, 393)
        XCTAssertEqual(layout.layerFrame.height, 393)
    }

    func testInvalidZoomIsRejected() {
        for zoom in [Double.nan, .infinity, 0, -1, 0.5] {
            XCTAssertNil(VideoSurfaceLayout(viewportWidth: 393, viewportHeight: 852,
                                            geometry: nil, zoomScale: zoom))
        }
    }

    func testPannedZoomKeepsTheSquareTargetMappedToTheMovedImage() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1920, height: 1080, rotationDegrees: 0))
        let layout = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 852, viewportHeight: 393, geometry: geometry,
                                                    zoomScale: 2, offsetX: -100, offsetY: -50))
        let image = try XCTUnwrap(layout.videoFrame)
        XCTAssertEqual(image.x, -372.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(image.y, -246.5, accuracy: 0.000_001)
        XCTAssertEqual(layout.layerFrame.x, image.x, accuracy: 0.000_001)
        XCTAssertEqual(layout.layerFrame.y, -552.166_666_666_7, accuracy: 0.000_001)
        // The square's centered aspect-fit content still lands on the moved image.
        let mappedY = layout.layerFrame.y + (1 - 1080.0 / 1920.0) * layout.layerFrame.height / 2
        XCTAssertEqual(mappedY, image.y, accuracy: 0.000_001)
    }

    func testPanOffsetIsClampedAndIgnoredForTheCompleteImage() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1920, height: 1080, rotationDegrees: 0))
        let clamped = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 852, viewportHeight: 393, geometry: geometry,
                                                     zoomScale: 2, offsetX: 10_000, offsetY: -10_000))
        let image = try XCTUnwrap(clamped.videoFrame)
        XCTAssertEqual(image.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(image.maxY, 393, accuracy: 0.000_001)
        let complete = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: 852, viewportHeight: 393, geometry: geometry,
                                                      zoomScale: 1, offsetX: 50, offsetY: 50))
        XCTAssertEqual(try XCTUnwrap(complete.videoFrame).x, 76.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(complete.videoFrame).y, 0, accuracy: 0.000_001)
    }

    func testPinchKeepsTheImagePointUnderTheFingers() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1920, height: 1080, rotationDegrees: 0))
        var zoom = VideoZoomState()
        zoom.pinch(by: 2, anchorX: 100, anchorY: 50, viewportWidth: 852, viewportHeight: 393, geometry: geometry)
        XCTAssertEqual(zoom.scale, 2)
        XCTAssertEqual(zoom.offsetX, -100, accuracy: 0.000_001)
        XCTAssertEqual(zoom.offsetY, -50, accuracy: 0.000_001)
        XCTAssertTrue(zoom.isZoomed)
        zoom.pan(byX: 1_000, y: -1_000, viewportWidth: 852, viewportHeight: 393, geometry: geometry)
        XCTAssertEqual(zoom.offsetX, 272.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual(zoom.offsetY, -196.5, accuracy: 0.000_001)
    }

    func testPinchIsBoundedAndSmallMagnificationsSnapBack() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1080, height: 1920, rotationDegrees: 0))
        var zoom = VideoZoomState()
        zoom.pinch(by: 10, anchorX: 0, anchorY: 0, viewportWidth: 393, viewportHeight: 852, geometry: geometry)
        XCTAssertEqual(zoom.scale, VideoZoomState.maximumScale)
        zoom.pinch(by: 0.1, anchorX: 40, anchorY: -40, viewportWidth: 393, viewportHeight: 852, geometry: geometry)
        XCTAssertEqual(zoom.scale, 1)
        XCTAssertEqual(zoom.offsetX, 0)
        XCTAssertEqual(zoom.offsetY, 0)
        zoom.pinch(by: 1.05, anchorX: 0, anchorY: 0, viewportWidth: 393, viewportHeight: 852, geometry: geometry)
        zoom.settle(viewportWidth: 393, viewportHeight: 852, geometry: geometry)
        XCTAssertFalse(zoom.isZoomed)
        zoom.pan(byX: 30, y: 30, viewportWidth: 393, viewportHeight: 852, geometry: geometry)
        XCTAssertEqual(zoom.offsetX, 0)
        zoom.setCentered(scale: 2)
        XCTAssertEqual(zoom.scale, 2)
        zoom.reset()
        XCTAssertEqual(zoom, VideoZoomState())
    }

    func testInvalidPinchInputLeavesZoomUnchanged() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 1920, height: 1080, rotationDegrees: 0))
        var zoom = VideoZoomState()
        for factor in [Double.nan, .infinity, 0, -2] {
            zoom.pinch(by: factor, anchorX: 0, anchorY: 0, viewportWidth: 852, viewportHeight: 393, geometry: geometry)
        }
        XCTAssertEqual(zoom, VideoZoomState())
    }

    private func layout(width: Double, height: Double, videoWidth: Double, videoHeight: Double,
                        zoom: Double = 1) throws -> VideoSurfaceLayout {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: videoWidth, height: videoHeight, rotationDegrees: 0))
        return try XCTUnwrap(VideoSurfaceLayout(viewportWidth: width, viewportHeight: height,
                                               geometry: geometry, zoomScale: zoom))
    }

    /// Project mpv's centered aspect-fit video rectangle within its square target
    /// through the actual layer transform; only complete-image mode forbids clipping.
    private func assertDecoderImageMapsExactly(_ layout: VideoSurfaceLayout,
                                               viewportWidth: Double, viewportHeight: Double,
                                               videoWidth: Double, videoHeight: Double,
                                               contained: Bool = true,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try XCTUnwrap(layout.videoFrame, file: file, line: line)
        let ratio = videoWidth / videoHeight
        let normalizedWidth = min(1, ratio)
        let normalizedHeight = min(1, 1 / ratio)
        let square = layout.layerFrame
        let mappedX = square.x + (1 - normalizedWidth) * square.width / 2
        let mappedY = square.y + (1 - normalizedHeight) * square.height / 2
        let mappedWidth = square.width * normalizedWidth
        let mappedHeight = square.height * normalizedHeight
        XCTAssertEqual(mappedX, expected.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(mappedY, expected.y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(mappedWidth, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(mappedHeight, expected.height, accuracy: 0.000_001, file: file, line: line)
        if contained {
            XCTAssertGreaterThanOrEqual(mappedX, -0.000_001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(mappedY, -0.000_001, file: file, line: line)
            XCTAssertLessThanOrEqual(mappedX + mappedWidth, viewportWidth + 0.000_001, file: file, line: line)
            XCTAssertLessThanOrEqual(mappedY + mappedHeight, viewportHeight + 0.000_001, file: file, line: line)
        }
        XCTAssertEqual(mappedWidth / mappedHeight, ratio, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(mappedX + mappedWidth / 2, viewportWidth / 2, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(mappedY + mappedHeight / 2, viewportHeight / 2, accuracy: 0.000_001, file: file, line: line)
    }
}
