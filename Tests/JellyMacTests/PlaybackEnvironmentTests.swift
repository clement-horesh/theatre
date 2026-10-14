import IOKit.pwr_mgt
import XCTest
@testable import JellyMac

final class PlaybackEnvironmentTests: XCTestCase {
    @MainActor
    func testCursorNeverHidesOutsideTheActivePlayerAndRestoresOnFocusLoss() {
        var changes: [Bool] = []
        let cursor = PlaybackCursorState(setHidden: { changes.append($0) })
        cursor.update(controlsHidden: true, pointerInVideo: false, windowIsKey: true, applicationIsActive: true)
        cursor.update(controlsHidden: true, pointerInVideo: true, windowIsKey: false, applicationIsActive: true)
        cursor.update(controlsHidden: true, pointerInVideo: true, windowIsKey: true, applicationIsActive: false)
        XCTAssertTrue(changes.isEmpty)
        cursor.update(controlsHidden: true, pointerInVideo: true, windowIsKey: true, applicationIsActive: true)
        cursor.update(controlsHidden: true, pointerInVideo: true, windowIsKey: true, applicationIsActive: true)
        XCTAssertEqual(changes, [true])
        cursor.update(controlsHidden: true, pointerInVideo: true, windowIsKey: false, applicationIsActive: true)
        cursor.restore()
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor
    func testPlaybackActivityShowsCursorAgainAfterControlsAutoHide() async throws {
        var changes: [Bool] = []
        let cursor = PlaybackCursorState(setHidden: { changes.append($0) })
        let chrome = PlayerChromeState()
        defer { chrome.cancel(); cursor.restore() }
        chrome.activity(isPlaying: true, delay: 0.01)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(chrome.isVisible)
        cursor.update(controlsHidden: !chrome.isVisible, pointerInVideo: true,
                      windowIsKey: true, applicationIsActive: true)
        chrome.activity(isPlaying: false)
        cursor.update(controlsHidden: !chrome.isVisible, pointerInVideo: true,
                      windowIsKey: true, applicationIsActive: true)
        XCTAssertTrue(chrome.isVisible)
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor
    func testTemporaryDisplaySleepAssertionIsReusedAndReleased() throws {
        let protection = PlaybackSleepProtection()
        defer { protection.release() }
        protection.update(isPlaying: true, watchingInForeground: false)
        let identifier = protection.assertionID
        XCTAssertNotEqual(identifier, IOPMAssertionID(kIOPMNullAssertionID))
        let copied = try XCTUnwrap(IOPMAssertionCopyProperties(identifier)?.takeRetainedValue())
        let properties = copied as NSDictionary
        XCTAssertEqual(properties[kIOPMAssertionTypeKey] as? String, kIOPMAssertionTypePreventUserIdleDisplaySleep)
        protection.update(isPlaying: true, watchingInForeground: false)
        XCTAssertEqual(protection.assertionID, identifier)
        protection.update(isPlaying: false, watchingInForeground: false)
        XCTAssertEqual(protection.assertionID, IOPMAssertionID(kIOPMNullAssertionID))
        XCTAssertNil(IOPMAssertionCopyProperties(identifier))
    }

    @MainActor
    func testDiscardingPlaybackOwnerReleasesItsSleepAssertion() {
        var protection: PlaybackSleepProtection? = PlaybackSleepProtection()
        protection?.update(isPlaying: true, watchingInForeground: false)
        let identifier = protection!.assertionID
        XCTAssertNotEqual(identifier, IOPMAssertionID(kIOPMNullAssertionID))
        protection = nil
        XCTAssertNil(IOPMAssertionCopyProperties(identifier))
    }
}
