import XCTest
@testable import MacSequator

final class MetadataDisplayTests: XCTestCase {
    func testCameraNameDoesNotRepeatTheMaker() {
        var info = RawMetadataInfo()
        info.cameraMake = "Canon"
        info.cameraModel = "Canon EOS 6D"
        XCTAssertEqual(info.cameraDisplayName, "Canon EOS 6D")
        info.cameraMake = "SONY"
        info.cameraModel = "ILCE-7M4"
        XCTAssertEqual(info.cameraDisplayName, "SONY ILCE-7M4")
        info.cameraMake = "NIKON CORPORATION"
        info.cameraModel = "NIKON Z 6_2"
        XCTAssertEqual(info.cameraDisplayName, "NIKON Z 6_2")
        info.cameraMake = ""
        XCTAssertEqual(info.cameraDisplayName, "NIKON Z 6_2")
    }
}
