import SwiftUI

nonisolated struct PlaybackClockSchedule: TimelineSchedule {
    var isRunning: Bool
    var interval: TimeInterval = 1.0 / 30
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard isRunning else { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: interval).entries(from: startDate, mode: mode))
    }
}
