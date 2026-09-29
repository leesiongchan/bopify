import SwiftUI

nonisolated struct PlaybackClockSchedule: TimelineSchedule {
    var isRunning: Bool
    var reduceMotion: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard isRunning else { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: reduceMotion ? 1 : 1.0 / 30).entries(from: startDate, mode: mode))
    }
}
