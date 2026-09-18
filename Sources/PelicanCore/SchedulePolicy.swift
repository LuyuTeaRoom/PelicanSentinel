import Foundation

/// Pure scheduling calculations. The caller owns persistence and serialization.
public enum SchedulePolicy {
    private static let defaultIntervalHours = 4

    public static func consumeDue(next: Date, now: Date, intervalHours: Int) -> (scheduledAt: Date, next: Date)? {
        let interval = intervalDuration(hours: intervalHours)
        guard next <= now else { return nil }

        let elapsed = max(0, now.timeIntervalSince(next))
        let missedIntervals = Int(floor(elapsed / interval))
        let nextScheduled = next.addingTimeInterval(Double(missedIntervals + 1) * interval)
        return (scheduledAt: next, next: nextScheduled)
    }

    public static func reschedule(now: Date, intervalHours: Int) -> Date {
        now.addingTimeInterval(intervalDuration(hours: intervalHours))
    }

    private static func intervalDuration(hours: Int) -> TimeInterval {
        let normalizedHours: Int
        switch hours {
        case 1, 2, 4:
            normalizedHours = hours
        default:
            normalizedHours = defaultIntervalHours
        }
        return TimeInterval(normalizedHours * 60 * 60)
    }
}
