import XCTest
@testable import Zeron

/// Committing a queued-message edit rewrites only what the composer showed.
final class QueueEditTests: XCTestCase {
    func testPlainTextIsReplaced() {
        XCTAssertEqual(CoreSessionSource.replacingVisible(in: "fix the build", visible: "fix the build", with: "fix the tests"), "fix the tests")
    }

    func testHiddenContextAfterTheVisibleTextSurvives() {
        let raw = "fix this\n\n<appshot-context>window: Xcode</appshot-context>"
        XCTAssertEqual(
            CoreSessionSource.replacingVisible(in: raw, visible: "fix this", with: "fix this please"),
            "fix this please\n\n<appshot-context>window: Xcode</appshot-context>"
        )
    }

    func testAttachmentOnlyRowKeepsItsTrailer() {
        let raw = "[image: /tmp/a.png]"
        XCTAssertEqual(
            CoreSessionSource.replacingVisible(in: raw, visible: "See the attached image(s).", with: "What's wrong here?"),
            "What's wrong here?\n\n[image: /tmp/a.png]"
        )
    }

    func testBlankEditStaysBlank() {
        XCTAssertEqual(CoreSessionSource.replacingVisible(in: "a\n\nctx", visible: "a", with: "  "), "  ")
    }
}
