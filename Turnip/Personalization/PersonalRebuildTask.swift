import BackgroundTasks
import Foundation
import os

/// Runs the personal layer's rebuild as a `BGProcessingTask` on external power
/// (`docs/PERSONALIZATION_DESIGN.md` §6.2): deferrable work the user never waits on. The identifier
/// is listed under `BGTaskSchedulerPermittedIdentifiers` in the Info.plist.
enum PersonalRebuildTask {
    static let identifier = "com.hoiekim.turnip.personal-rebuild"

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "Personalization")

    static let scheduler = PersonalRebuildScheduler(schedule: schedule, cancel: cancel)

    /// Has to run before the app finishes launching, for the system to hand the task back.
    static func register() {
        let isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                let finished = await PersonalLayer.shared.rebuild { Task.isCancelled }
                task.setTaskCompleted(success: finished)
            }
            task.expirationHandler = { work.cancel() }
        }
        if !isRegistered {
            logger.error("Personal rebuild task didn't register")
        }
    }

    private static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator has no background tasks, and a device can refuse one; the next time the
            // layer finds work outstanding it asks again.
            logger.notice("Personal rebuild not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
