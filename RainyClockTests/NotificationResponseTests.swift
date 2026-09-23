import XCTest
import UserNotifications
@testable import RainyClock

@MainActor
final class NotificationResponseTests: XCTestCase {
    @MainActor
    private final class ResponseEvents {
        var values: [String] = []
    }

    private func checkResponse(action: String, category: String, shouldAcknowledge: Bool) async {
        let finished = expectation(description: "notification completion")
        finished.assertForOverFulfill = true
        let deliveredAt = Date(timeIntervalSince1970: 1_790_000_000)
        let events = ResponseEvents()

        // UserNotifications can deliver responses on a worker thread. Exercise
        // that entry point and verify completion stays on main after suspension.
        await Task.detached {
            NotificationPresentationDelegate.handleResponse(
                actionIdentifier: action,
                categoryIdentifier: category,
                deliveredAt: deliveredAt,
                acknowledge: { date in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(date, deliveredAt)
                    events.values.append("acknowledge started")
                    await Task.yield()
                    XCTAssertEqual(events.values, ["acknowledge started"])
                    events.values.append("acknowledge finished")
                },
                completion: {
                    XCTAssertTrue(Thread.isMainThread)
                    events.values.append("completion")
                    finished.fulfill()
                }
            )
        }.value

        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events.values, shouldAcknowledge
            ? ["acknowledge started", "acknowledge finished", "completion"]
            : ["completion"])
    }

    func testTappingAlarmAcknowledgesBeforeMainThreadCompletion() async {
        await checkResponse(action: UNNotificationDefaultActionIdentifier,
                            category: LocalNotificationScheduler.categoryIdentifier,
                            shouldAcknowledge: true)
    }

    func testStopActionAcknowledgesBeforeMainThreadCompletion() async {
        await checkResponse(action: LocalNotificationScheduler.stopActionIdentifier,
                            category: LocalNotificationScheduler.categoryIdentifier,
                            shouldAcknowledge: true)
    }

    func testDismissingAlarmCompletesWithoutAcknowledging() async {
        await checkResponse(action: UNNotificationDismissActionIdentifier,
                            category: LocalNotificationScheduler.categoryIdentifier,
                            shouldAcknowledge: false)
    }

    func testUnknownActionCompletesWithoutAcknowledging() async {
        await checkResponse(action: "unknown-action",
                            category: LocalNotificationScheduler.categoryIdentifier,
                            shouldAcknowledge: false)
    }

    func testUnrelatedNotificationCompletesWithoutAcknowledging() async {
        await checkResponse(action: UNNotificationDefaultActionIdentifier,
                            category: "evening-preview",
                            shouldAcknowledge: false)
    }
}
