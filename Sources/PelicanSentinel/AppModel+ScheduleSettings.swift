import Foundation
import PelicanCore

@MainActor
extension AppModel {
    func setInterval(_ hours: Int) {
        guard !shuttingDown, [1, 2, 4].contains(hours) else { return }

        let previous = settings
        var updated = previous
        updated.intervalHours = hours
        updated.nextScheduledAt = SchedulePolicy.reschedule(now: Date(), intervalHours: hours)
        updated.pendingScheduledAt = nil

        do {
            try store.saveSettings(updated)
            settings = updated
            if let pending = previous.pendingScheduledAt {
                removePendingNotification(pending)
            }
        } catch {
            message = l("无法保存设置，请检查存储权限。", "Could not save settings. Check storage permissions.")
        }
    }

    func setMode(_ mode: GenerationMode) {
        guard !shuttingDown else { return }

        let previous = settings
        var updated = previous
        updated.mode = mode
        updated.pendingScheduledAt = nil

        do {
            try store.saveSettings(updated)
            settings = updated
            if let pending = previous.pendingScheduledAt {
                removePendingNotification(pending)
            }
            if !testing {
                requestNotifications()
            }
        } catch {
            message = l("无法保存设置，请检查存储权限。", "Could not save settings. Check storage permissions.")
        }
    }
}
