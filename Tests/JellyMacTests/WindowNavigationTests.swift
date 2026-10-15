import XCTest

@testable import JellyMac

final class WindowNavigationTests: XCTestCase {
    func testEveryWindowPhaseHasExactlyOneNavigationSurface() {
        let phases: [LibraryWindowPhase] = [.windowed, .enteringFullscreen, .fullscreen, .exitingFullscreen]
        for phase in phases {
            let visible = [phase.showsPageNavigation, phase.showsToolbarNavigation].filter { $0 }.count
            XCTAssertEqual(visible, 1, "Navigation must neither disappear nor duplicate during \(phase)")
        }
    }
}
