import BackgroundTasks
import Foundation
import SwiftData

/// Schedules and handles the nightly automatic tidy pass.
enum BackgroundTaskScheduler {
    static let tidyTaskIdentifier = "app.savant.tidy"

    /// Default scheduled time: 3 AM device-local. Returns the next occurrence after `from`.
    static func nextScheduledDate(from: Date = Date(), hour: Int = 3) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: from)
        components.hour = hour
        components.minute = 0
        let candidate = calendar.date(from: components) ?? from.addingTimeInterval(60 * 60)
        return candidate > from ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    /// Register the task handler. Must be called from app init (before scene setup).
    static func register(modelContainer: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: tidyTaskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(appRefreshTask, modelContainer: modelContainer)
        }
    }

    /// Submit a request for the next nightly run. Call after a successful tidy and at app launch.
    static func schedule(after date: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: tidyTaskIdentifier)
        request.earliestBeginDate = nextScheduledDate(from: date)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BG scheduling fails on simulator and when the app isn't yet authorized.
            // No-op — manual tidy still works.
            #if DEBUG
            print("BGTask submit failed: \(error)")
            #endif
        }
    }

    private static func handle(_ task: BGAppRefreshTask, modelContainer: ModelContainer) {
        // Always reschedule so the chain continues even if this run is throttled.
        schedule()

        let workItem = Task<Void, Never> { @MainActor in
            await runTidyForAllSpaces(modelContainer: modelContainer)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            workItem.cancel()
        }
    }

    @MainActor
    static func runTidyForAllSpaces(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        do {
            let spaces = try context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\Space.sortIndex)]))
            let notes = try context.fetch(FetchDescriptor<Note>())
            let service = TidyService(context: context)
            for space in spaces {
                _ = try? await service.tidy(space: space, notes: notes, trigger: .scheduled)
            }
        } catch {
            #if DEBUG
            print("Background tidy failed: \(error)")
            #endif
        }
    }
}
