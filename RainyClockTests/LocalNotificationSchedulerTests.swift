import XCTest
import UserNotifications
@testable import RainyClock

/// The iOS 17–25 notification alarm, run against a fake pending-request queue. Each test
/// puts "this morning's" ring a few minutes in the past, so its follow-up chain (ring +
/// k × snooze) is still firing when the test acknowledges and re-registers.
final class LocalNotificationSchedulerTests: XCTestCase {
    private final class FakeCenter: AlarmNotificationCenter, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String: (request: UNNotificationRequest, addedAt: Date)] = [:]

        func pendingNotificationRequests() async -> [UNNotificationRequest] {
            lock.withLock { requests.values.map(\.request) }
        }

        func add(_ request: UNNotificationRequest) async throws {
            lock.withLock { requests[request.identifier] = (request, Date()) }
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            lock.withLock { identifiers.forEach { requests[$0] = nil } }
        }

        func deliveredNotificationIdentifiers() async -> [String] { [] }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

        var count: Int { lock.withLock { requests.count } }

        /// When each pending alarm request fires next.
        var fireDates: [Date] {
            lock.withLock {
                requests.values.compactMap { entry in
                    switch entry.request.trigger {
                    case let trigger as UNCalendarNotificationTrigger:
                        trigger.nextTriggerDate()
                    case let trigger as UNTimeIntervalNotificationTrigger:
                        entry.addedAt.addingTimeInterval(trigger.timeInterval)
                    default:
                        nil
                    }
                }
            }
        }

        func fires(within interval: TimeInterval, of now: Date) -> [Date] {
            fireDates.filter { $0 > now && $0 < now.addingTimeInterval(interval) }.sorted()
        }
    }

    private let center = FakeCenter()
    private var scheduler: LocalNotificationScheduler!

    override func setUp() {
        super.setUp()
        let suite = "LocalNotificationSchedulerTests.\(UUID().uuidString)"
        scheduler = LocalNotificationScheduler(center: center, defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    private func scheduleWeekly(ringingAt ring: Date, snoozeMinutes: Int = 5) async throws {
        try await scheduler.scheduleAlarm(at: ring, normalAlarmDate: ring, weekdays: CommuteAlarmSettings.allWeekdays,
            sound: .rainyClock, soundFileNameOverride: nil, snoozeMinutes: snoozeMinutes, title: "Alarm", body: "Wake up")
    }

    // All seven weekdays and a 5-minute snooze: a ring plus 7 follow-ups, 35 minutes in all.

    func testReRegisteringWithoutAcknowledgingKeepsTheFollowUps() async throws {
        let ring = Date().addingTimeInterval(-450)
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600, of: Date()).count, 6)

        // Nobody stopped it: the chain goes on nagging after a re-registration.
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600, of: Date()).count, 6)
    }

    func testReRegisteringTheWeeklyPlanKeepsAnAcknowledgedMorningSilent() async throws {
        let ring = Date().addingTimeInterval(-450)
        try await scheduleWeekly(ringingAt: ring)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())
        XCTAssertEqual(center.fires(within: 3_600, of: Date()), [])

        // A foreground refresh or settings change re-registers the same weekly alarm.
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600, of: Date()), [], "the acknowledged follow-ups came back")
        XCTAssertEqual(center.count, 7 * 8, "the silenced follow-ups must stay armed for next week")
    }

    func testStoppingABannerDeliveredBeforeAReRegistrationSilencesTheMorning() async throws {
        let ring = Date().addingTimeInterval(-450)
        try await scheduleWeekly(ringingAt: ring)
        let delivered = Date()
        // A refresh re-registers the weekly alarm before the user reaches that banner.
        try await scheduleWeekly(ringingAt: ring)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: delivered)
        XCTAssertEqual(center.fires(within: 3_600, of: Date()), [])
    }

    func testMovingTheWeeklyAlarmEarlierKeepsAnAcknowledgedMorningSilent() async throws {
        let ring = Date().addingTimeInterval(-450)
        try await scheduleWeekly(ringingAt: ring)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())

        // Tomorrow's rain moves the one repeating time earlier; that chain's tail would
        // also land on this morning, which was already stopped.
        try await scheduleWeekly(ringingAt: ring.addingTimeInterval(-10 * 60))
        XCTAssertEqual(center.fires(within: 3_600, of: Date()), [])
    }

    func testLengtheningSnoozeAfterAcknowledgingKeepsTheMorningSilent() async throws {
        let ring = Date().addingTimeInterval(-450)
        try await scheduleWeekly(ringingAt: ring)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())

        // At 10 minutes the chain runs 70 minutes, past the window the 5-minute chain had.
        try await scheduleWeekly(ringingAt: ring, snoozeMinutes: 10)
        XCTAssertEqual(center.fires(within: 3 * 3_600, of: Date()), [])
        XCTAssertEqual(center.count, 7 * 8)
    }

    func testAcknowledgedMorningDoesNotSilenceALaterRingSetToday() async throws {
        let ring = Date().addingTimeInterval(-450)
        try await scheduleWeekly(ringingAt: ring)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())

        // After stopping this morning's alarm the user sets it for later today: that is
        // a new ring, and it rings with its own follow-ups.
        let later = Date().addingTimeInterval(10 * 60)
        try await scheduleWeekly(ringingAt: later)
        let fires = center.fires(within: 3_600, of: Date())
        XCTAssertEqual(fires.count, 8)
        XCTAssertEqual(fires.first?.timeIntervalSince(later) ?? 99, 0, accuracy: 1)
    }

    func testSwitchingFromDatedToWeeklyKeepsAnAcknowledgedMorningSilent() async throws {
        let ring = Date().addingTimeInterval(-180)
        let plan = CalendarAlarmPlan(occurrences: [.init(normalDate: ring, ringDate: ring)],
                                     coveredUntil: ring.addingTimeInterval(8 * 86_400))
        try await scheduler.scheduleCalendar(plan, sound: .rainyClock, soundFileNameOverride: nil,
                                             snoozeMinutes: 5, title: "Alarm", body: "Wake up")
        XCTAssertEqual(center.fires(within: 3_600, of: Date()).count, 1)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())
        XCTAssertEqual(center.fires(within: 3_600, of: Date()), [])

        // Turning the calendar exceptions off goes back to the weekly alarm at the same time.
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600, of: Date()), [])
    }
}
