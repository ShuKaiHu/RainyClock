import XCTest
import UserNotifications
@testable import RainyClock

/// The notification alarm against the simulator's real pending-request queue. The fake in
/// `LocalNotificationSchedulerTests` cannot show that UserNotifications hands back what the
/// scheduler relies on at the next registration: calendar triggers it can date, carried
/// requests' `chainStart` in userInfo, one-shot triggers that stay one-shot. Each test waits
/// a few seconds for a real ring time to pass.
final class LocalNotificationSchedulerSystemTests: XCTestCase {
    private let center = UNUserNotificationCenter.current()
    private var scheduler: LocalNotificationScheduler!

    override func setUp() async throws {
        let suite = "LocalNotificationSchedulerSystemTests.\(UUID().uuidString)"
        let scheduler = LocalNotificationScheduler(defaults: UserDefaults(suiteName: suite)!)
        self.scheduler = scheduler
        await scheduler.cancelScheduledAlarms()
        addTeardownBlock {
            await scheduler.cancelScheduledAlarms()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    /// Not a check: the tests below skip until the app may post notifications, and simctl
    /// cannot grant that. Once per simulator, run this with
    /// `TEST_RUNNER_RAINYCLOCK_ASK_NOTIFICATIONS=1` and `-parallel-testing-enabled NO` (so the
    /// answer lands on the simulator itself, not on a throwaway parallel clone), then tap Allow.
    func testAskForNotificationPermission() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAINYCLOCK_ASK_NOTIFICATIONS"] != nil)
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        XCTAssertTrue(granted)
    }

    private func alarms() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("commute-rain-alarm") }
    }

    /// Distinct fire times in the next ten minutes, as the real queue holds them.
    private func firesSoon() async -> [Date] {
        let now = Date()
        let dates = await alarms().compactMap { request -> Date? in
            switch request.trigger {
            case let trigger as UNCalendarNotificationTrigger: LocalNotificationScheduler.nextFireDate(of: trigger, after: now)
            case let trigger as UNTimeIntervalNotificationTrigger: trigger.nextTriggerDate()
            default: nil
            }
        }
        return dates.filter { $0 > now && $0 < now.addingTimeInterval(600) }.sorted()
    }

    /// Without permission the queue refuses requests, and how differs by release (iOS 18:
    /// `.notificationsNotAllowed`; iOS 27: UNErrorDomain 2003), so ask the status instead.
    private func requirePermission() async throws {
        let status = await center.notificationSettings().authorizationStatus
        try XCTSkipUnless(status == .authorized, "This simulator has not allowed Rainy Clock to post notifications")
    }

    /// A weekly alarm two seconds from now, one-minute follow-ups: seven of them on seven days.
    private func scheduleWeekly(ringingAt ring: Date) async throws {
        try await scheduler.scheduleAlarm(at: ring, normalAlarmDate: ring, weekdays: CommuteAlarmSettings.allWeekdays,
            sound: .rainyClock, soundFileNameOverride: nil, snoozeMinutes: 1, title: "Alarm", body: "Wake up")
    }

    private func letTheRingPass(_ ring: Date) async throws {
        try await Task.sleep(for: .seconds(max(0, ring.timeIntervalSinceNow) + 1.5))
    }

    func testAnUnstoppedChainSurvivesReRegistrationUntilStopped() async throws {
        try await requirePermission()
        let ring = Date().addingTimeInterval(2).rounded()
        try await scheduleWeekly(ringingAt: ring)
        let registered = await alarms()
        XCTAssertEqual(registered.count, 56)
        try await letTheRingPass(ring)
        let chain = (1...7).map { ring.addingTimeInterval(Double($0) * 60) }
        var fires = await firesSoon()
        XCTAssertEqual(fires, chain)

        // Re-registered twice mid-chain: the second pass reads back the first one's carried requests.
        try await scheduleWeekly(ringingAt: ring)
        try await scheduleWeekly(ringingAt: ring)
        let carried = await alarms().filter { $0.identifier.contains("-carry-") }
        XCTAssertEqual(carried.count, 7)
        for request in carried {
            XCTAssertEqual(request.content.userInfo["chainStart"] as? TimeInterval, ring.timeIntervalSince1970)
            XCTAssertEqual((request.trigger as? UNCalendarNotificationTrigger)?.repeats, false)
            XCTAssertEqual(request.content.categoryIdentifier, LocalNotificationScheduler.categoryIdentifier)
        }
        let total = await alarms().count
        XCTAssertLessThanOrEqual(total, 56)
        fires = await firesSoon()
        XCTAssertEqual(fires, chain)

        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())
        fires = await firesSoon()
        XCTAssertEqual(fires, [])
        let leftover = await alarms().filter { $0.identifier.contains("-carry-") }
        XCTAssertEqual(leftover.count, 0)
    }

    /// Watches the system actually deliver: the ring, a follow-up after a mid-chain
    /// re-registration that moves the alarm, and nothing after Stop. About two and a half
    /// minutes, so it runs only with `TEST_RUNNER_RAINYCLOCK_LIVE_NOTIFICATIONS=1`.
    func testDeliveredFollowUpsOutliveAReRegistrationAndStopAtStop() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAINYCLOCK_LIVE_NOTIFICATIONS"] != nil)
        try await requirePermission()
        center.removeAllDeliveredNotifications()
        let ring = Date().addingTimeInterval(3).rounded()
        try await scheduleWeekly(ringingAt: ring)
        try await letTheRingPass(ring)
        var delivered = await deliveredAlarms()
        assertDelivered(delivered, at: [ring], "the ring itself")

        // A background refresh moves the one weekly time 30 minutes earlier mid-chain.
        try await scheduleWeekly(ringingAt: ring.addingTimeInterval(-30 * 60))
        try await Task.sleep(for: .seconds(ring.addingTimeInterval(62).timeIntervalSinceNow))
        delivered = await deliveredAlarms()
        assertDelivered(delivered, at: [ring, ring.addingTimeInterval(60)], "the first follow-up still rang")
        XCTAssertTrue(delivered.last?.request.identifier.contains("-carry-") == true)

        // Stop on that follow-up: nothing more this morning.
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: delivered.last!.date)
        try await Task.sleep(for: .seconds(ring.addingTimeInterval(125).timeIntervalSinceNow))
        let after = await deliveredAlarms()
        XCTAssertTrue(after.allSatisfy { $0.date < ring.addingTimeInterval(61) }, "rang after Stop: \(after.map(\.date))")
    }

    /// Delivery lands a moment after the trigger time.
    private func assertDelivered(_ delivered: [UNNotification], at expected: [Date], _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let times = delivered.map(\.date)
        XCTAssertEqual(times.count, expected.count, "\(message): \(times)", file: file, line: line)
        for (time, due) in zip(times, expected) {
            XCTAssertEqual(time.timeIntervalSince(due), 0, accuracy: 3, "\(message): \(times)", file: file, line: line)
        }
    }

    private func deliveredAlarms() async -> [UNNotification] {
        await center.deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix("commute-rain-alarm") }
            .sorted { $0.date < $1.date }
    }

    func testAnUnstoppedChainSurvivesASwitchToTheDatedPlan() async throws {
        try await requirePermission()
        let ring = Date().addingTimeInterval(2).rounded()
        try await scheduleWeekly(ringingAt: ring)
        let registered = await alarms()
        try await letTheRingPass(ring)

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: ring)!
        let plan = CalendarAlarmPlan(occurrences: [.init(normalDate: tomorrow, ringDate: tomorrow)],
                                     coveredUntil: tomorrow.addingTimeInterval(86_400))
        try await scheduler.scheduleCalendar(plan, sound: .rainyClock, soundFileNameOverride: nil,
                                             snoozeMinutes: 1, title: "Alarm", body: "Wake up")
        var fires = await firesSoon()
        XCTAssertEqual(fires, (1...7).map { ring.addingTimeInterval(Double($0) * 60) })

        await scheduler.acknowledgeAlarm(notificationDeliveredAt: Date())
        fires = await firesSoon()
        XCTAssertEqual(fires, [])
        let remaining = await alarms().map(\.identifier).sorted()
        XCTAssertEqual(remaining,
                       ["commute-rain-alarm-date-\(AlarmCalendarSettings.key(for: tomorrow))-0",
                        "commute-rain-alarm-date-\(AlarmCalendarSettings.key(for: tomorrow))-60"])
    }
}

private extension Date {
    /// Whole seconds: calendar triggers carry no fractions, so the chain compares exactly.
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.up)) }
}
