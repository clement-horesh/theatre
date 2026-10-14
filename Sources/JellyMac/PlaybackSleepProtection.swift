import Foundation
import IOKit.pwr_mgt

/// Temporary playback assertions; no power or screen-lock settings are changed.
@MainActor
final class PlaybackSleepProtection {
    private(set) var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var userActivityID = IOPMAssertionID(kIOPMNullAssertionID)
    private var lastUserActivity: TimeInterval?
    private let reason = "Theatre video playback" as CFString

    func update(isPlaying: Bool, watchingInForeground: Bool) {
        guard isPlaying else { release(); return }
        if assertionID == kIOPMNullAssertionID {
            var identifier = IOPMAssertionID(kIOPMNullAssertionID)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), reason,
                                         &identifier) == kIOReturnSuccess {
                assertionID = identifier
            }
        }
        // Active viewing counts as activity for the idle screensaver/lock timer.
        // Stop refreshing when another app or the lock screen takes focus.
        guard watchingInForeground else {
            releaseUserActivity()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if lastUserActivity == nil || now - lastUserActivity! >= 15 {
            if IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &userActivityID) == kIOReturnSuccess {
                lastUserActivity = now
            }
        }
    }

    func release() {
        if assertionID != kIOPMNullAssertionID { IOPMAssertionRelease(assertionID) }
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        releaseUserActivity()
    }

    private func releaseUserActivity() {
        if userActivityID != kIOPMNullAssertionID { IOPMAssertionRelease(userActivityID) }
        userActivityID = IOPMAssertionID(kIOPMNullAssertionID)
        lastUserActivity = nil
    }

    deinit {
        if assertionID != kIOPMNullAssertionID { IOPMAssertionRelease(assertionID) }
        if userActivityID != kIOPMNullAssertionID { IOPMAssertionRelease(userActivityID) }
    }
}
