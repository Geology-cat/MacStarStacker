import XCTest
@testable import MacSequator

final class ImageImportSupportTests: XCTestCase {
    func testFolderExpansionFiltersSortsAndDeduplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("b.JPG")
        let second = nested.appendingPathComponent("a.png")
        let ignored = directory.appendingPathComponent("notes.txt")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        try Data([3]).write(to: ignored)

        let result = ImageImportSupport.expandedImageURLs(from: [directory, first])
        XCTAssertEqual(result.map(\.lastPathComponent), ["b.JPG", "a.png"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        XCTAssertEqual(Set(result.map(\.path)).count, 2)
    }

    func testOpenPanelAllowsSupportedImagesAndFitsButRejectsOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jpeg = directory.appendingPathComponent("frame.jpg")
        let fits = directory.appendingPathComponent("frame.fits")
        let text = directory.appendingPathComponent("notes.txt")
        try Data([1]).write(to: jpeg)
        try Data([2]).write(to: fits)
        try Data([3]).write(to: text)

        let panel = ImageImportSupport.makeOpenPanel(title: "テスト")
        let delegate = try XCTUnwrap(panel.delegate)
        XCTAssertTrue(delegate.panel?(panel, shouldEnable: directory) ?? false)
        XCTAssertTrue(delegate.panel?(panel, shouldEnable: jpeg) ?? false)
        XCTAssertTrue(delegate.panel?(panel, shouldEnable: fits) ?? false)
        XCTAssertFalse(delegate.panel?(panel, shouldEnable: text) ?? true)
    }
}
