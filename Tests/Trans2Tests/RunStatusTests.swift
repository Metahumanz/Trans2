import Foundation
import Testing
import TransCore
@testable import Trans2

@Suite
struct RunStatusTests {
    @Test
    func durationFormattingSwitchesAtOneHour() {
        #expect(formatRunDuration(0) == "0:00")
        #expect(formatRunDuration(5) == "0:05")
        #expect(formatRunDuration(59) == "0:59")
        #expect(formatRunDuration(60) == "1:00")
        #expect(formatRunDuration(125) == "2:05")
        #expect(formatRunDuration(3599) == "59:59")
        #expect(formatRunDuration(3600) == "1:00:00")
        #expect(formatRunDuration(3661) == "1:01:01")
    }

    @Test
    func negativeDurationsClampToZero() {
        #expect(formatRunDuration(-5) == "0:00")
    }

    @Test
    func cueProgressFractionIsClampedByTotal() {
        let cue = CueProgress(stage: .translating, completed: 3, total: 4, successCount: 3, errorCount: 0)
        #expect(abs(cue.fraction - 0.75) < 0.0001)
        let empty = CueProgress(stage: .translating, completed: 0, total: 0, successCount: 0, errorCount: 0)
        #expect(empty.fraction == 0)
    }
}
