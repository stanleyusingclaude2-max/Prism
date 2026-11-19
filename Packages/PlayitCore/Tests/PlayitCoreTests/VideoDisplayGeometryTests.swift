import XCTest
@testable import PlayitCore

final class VideoDisplayGeometryTests: XCTestCase {
    func testPortraitContentChoosesPortraitFullscreen() throws {
        let video = try XCTUnwrap(resolve(width: 1080, height: 1920, rotation: 0))
        XCTAssertEqual(video.fullscreenOrientation, .portrait)
        XCTAssertEqual(video.aspectRatio, 9.0 / 16.0, accuracy: 0.000_001)
    }

    func testLandscapeContentChoosesLandscapeFullscreen() throws {
        let video = try XCTUnwrap(resolve(width: 1920, height: 1080, rotation: 0))
        XCTAssertEqual(video.fullscreenOrientation, .landscape)
    }

    func testPhonePortraitStoredWithNinetyDegreeRotation() throws {
        let video = try XCTUnwrap(resolve(width: 1920, height: 1080, rotation: 90))
        XCTAssertEqual(video.width, 1080)
        XCTAssertEqual(video.height, 1920)
        XCTAssertEqual(video.fullscreenOrientation, .portrait)
    }

    func testPhonePortraitStoredWithTwoHundredSeventyDegreeRotation() throws {
        let video = try XCTUnwrap(resolve(width: 1920, height: 1080, rotation: 270))
        XCTAssertEqual(video.fullscreenOrientation, .portrait)
        XCTAssertEqual(video.aspectRatio, 9.0 / 16.0, accuracy: 0.000_001)
    }

    func testLandscapeStoredInPortraitEncodedDimensions() throws {
        let video = try XCTUnwrap(resolve(width: 1080, height: 1920, rotation: 90))
        XCTAssertEqual(video.fullscreenOrientation, .landscape)
    }

    func testSquareContentRemainsPortraitAtEveryQuarterTurn() throws {
        for rotation in [0.0, 90, 180, 270] {
            let video = try XCTUnwrap(resolve(width: 1080, height: 1080, rotation: rotation))
            XCTAssertEqual(video.fullscreenOrientation, .portrait)
        }
    }

    func testPostFilterGeometryDoesNotApplySourceRotationTwice() throws {
        let video = try XCTUnwrap(VideoDisplayGeometry.resolve(
            outputWidth: 1080, outputHeight: 1920, outputRotation: 0,
            sourceWidth: 1920, sourceHeight: 1080, sourceRotation: 90
        ))
        XCTAssertEqual(video.width, 1080)
        XCTAssertEqual(video.height, 1920)
        XCTAssertEqual(video.fullscreenOrientation, .portrait)
    }

    func testOutputDisplayAspectWinsOverEncodedAspect() throws {
        let video = try XCTUnwrap(VideoDisplayGeometry.resolve(
            outputWidth: 1024, outputHeight: 576, outputRotation: 0,
            sourceWidth: 720, sourceHeight: 576, sourceRotation: 0
        ))
        XCTAssertEqual(video.aspectRatio, 16.0 / 9.0, accuracy: 0.000_001)
    }

    func testSourceFallbackAppliesDisplayAspectBeforeRotation() throws {
        let video = try XCTUnwrap(VideoDisplayGeometry.resolve(
            outputWidth: nil, outputHeight: nil, outputRotation: nil,
            sourceWidth: 720, sourceHeight: 576, sourceRotation: 90,
            sourceDisplayAspect: 16.0 / 9.0
        ))
        XCTAssertEqual(video.width, 576)
        XCTAssertEqual(video.height, 1024)
        XCTAssertEqual(video.fullscreenOrientation, .portrait)
    }

    func testMissingMetadataDoesNotGuessLandscape() {
        XCTAssertNil(VideoDisplayGeometry.resolve(outputWidth: nil, outputHeight: nil, outputRotation: nil))
    }

    func testEncodedDimensionsWithoutKnownRotationAreInsufficient() {
        XCTAssertNil(VideoDisplayGeometry.resolve(
            outputWidth: 1920, outputHeight: 1080, outputRotation: nil,
            sourceWidth: 1920, sourceHeight: 1080, sourceRotation: nil
        ))
    }

    func testUnavailableOutputFallsBackToKnownSourceTransform() throws {
        let video = try XCTUnwrap(VideoDisplayGeometry.resolve(
            outputWidth: 0, outputHeight: 0, outputRotation: 0,
            sourceWidth: 1920, sourceHeight: 1080, sourceRotation: 90
        ))
        XCTAssertEqual(video.fullscreenOrientation, .portrait)
    }

    func testNegativeRotationAndFullTurnsNormalizeCorrectly() throws {
        XCTAssertEqual(try XCTUnwrap(resolve(width: 1920, height: 1080, rotation: -90)).fullscreenOrientation, .portrait)
        XCTAssertEqual(try XCTUnwrap(resolve(width: 1920, height: 1080, rotation: 360)).fullscreenOrientation, .landscape)
        XCTAssertEqual(try XCTUnwrap(resolve(width: 1920, height: 1080, rotation: 450)).fullscreenOrientation, .portrait)
    }

    func testInvalidDimensionsAndRotationAreRejected() {
        for value in [Double.nan, .infinity, 0, -1] {
            XCTAssertNil(resolve(width: value, height: 1080, rotation: 0))
            XCTAssertNil(resolve(width: 1920, height: value, rotation: 0))
        }
        XCTAssertNil(resolve(width: 1920, height: 1080, rotation: .nan))
        XCTAssertNil(resolve(width: 1920, height: 1080, rotation: .infinity))
    }

    private func resolve(width: Double, height: Double, rotation: Double) -> VideoDisplayGeometry? {
        VideoDisplayGeometry.resolve(outputWidth: width, outputHeight: height, outputRotation: rotation)
    }
}
