import XCTest
#if canImport(AlarmKit)
import AlarmKit
#endif
@testable import RainyClock

#if canImport(AlarmKit)
/// The iOS 26 AlarmKit alarm, run against a fake alarm list the test moves the way the
/// system would: an alarm rings, is snoozed, is stopped. A re-registration — a stale
/// decision refreshed on opening the app, the closure rule turned off, a skip undone —
/// or a removal while the alarm stays on (a new address, no repeat day left) must leave a
/// ringing or snoozing alarm to finish, and must not leave it behind afterwards as a second
/// weekly alarm at the old time. Only turning the alarm off ends a snooze.
final class AlarmKitSchedulerTests: XCTestCase {
    @available(iOS 26.0, *)
    private final class FakeAlarms: AlarmKitManaging, @unchecked Sendable {
        private struct CancelRefused: Error {}

        private let lock = NSLock()
        private var list: [AlarmSnapshot] = []
        private var readable = true
        private var onSchedule: (@Sendable () -> Void)?
        private var refusedCancel: UUID?
        private var observers: [AsyncStream<Void>.Continuation] = []

        func alarms() throws -> [AlarmSnapshot] {
            try lock.withLock {
                guard readable else { throw CocoaError(.fileReadUnknown) }
                return list
            }
        }

        func schedule(id: UUID, request: AlarmRequest) async throws {
            let change = lock.withLock {
                list.removeAll { $0.id == id }
                list.append(AlarmSnapshot(id: id, state: .scheduled, schedule: request.schedule,
                                          countdownDuration: request.countdownDuration))
                return onSchedule
            }
            change?()
        }

        func cancel(id: UUID) throws {
            try lock.withLock {
                if refusedCancel == id { throw CancelRefused() }
                list.removeAll { $0.id == id }
            }
        }

        func changes() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            lock.withLock { observers.append(continuation) }
            return stream
        }

        /// The system moving an alarm on: it rings, is snoozed, is stopped. Observers hear of it.
        func move(_ id: UUID, to state: Alarm.State) {
            let observers = lock.withLock {
                if let index = list.firstIndex(where: { $0.id == id }) { list[index].state = state }
                return self.observers
            }
            observers.forEach { $0.yield() }
        }

        /// `cancel(id:)` throws for this alarm until set back to nil.
        func refuseCancel(of id: UUID?) {
            lock.withLock { refusedCancel = id }
        }

        var isObserved: Bool { lock.withLock { !observers.isEmpty } }

        /// A stopped one-time alarm, which the system drops.
        func drop(_ id: UUID) {
            lock.withLock { list.removeAll { $0.id == id } }
        }

        /// Runs while a registration is suspended in `schedule`.
        func whileScheduling(_ change: (@Sendable () -> Void)?) {
            lock.withLock { onSchedule = change }
        }

        func setReadable(_ value: Bool) {
            lock.withLock { readable = value }
        }

        func state(of id: UUID) -> Alarm.State? {
            lock.withLock { list.first { $0.id == id }?.state }
        }

        var identifiers: Set<UUID> { lock.withLock { Set(list.map(\.id)) } }
    }

    @available(iOS 26.0, *)
    private func makeScheduler() -> (AlarmKitScheduler, FakeAlarms) {
        let suite = "AlarmKitSchedulerTests.\(UUID().uuidString)"
        let alarms = FakeAlarms()
        let scheduler = AlarmKitScheduler(manager: alarms, defaults: UserDefaults(suiteName: suite)!,
                                          cancelNotificationAlarms: {})
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (scheduler, alarms)
    }

    /// Registers the weekday alarm at `hour:minute` and returns the alarm it added.
    @available(iOS 26.0, *)
    @discardableResult
    private func scheduleWeekly(_ scheduler: AlarmKitScheduler, _ alarms: FakeAlarms,
                                hour: Int, minute: Int) async throws -> UUID {
        let before = alarms.identifiers
        let ring = try XCTUnwrap(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()))
        try await scheduler.scheduleAlarm(at: ring, normalAlarmDate: ring, weekdays: [2, 3, 4, 5, 6],
            sound: .rainyClock, soundFileNameOverride: nil, snoozeMinutes: 5, title: "Alarm", body: "Wake up")
        return try XCTUnwrap(alarms.identifiers.subtracting(before).first)
    }

    @available(iOS 26.0, *)
    private func scheduleDated(_ scheduler: AlarmKitScheduler, ringingAt ringDates: [Date]) async throws {
        let plan = CalendarAlarmPlan(occurrences: ringDates.map { .init(normalDate: $0, ringDate: $0) },
                                     coveredUntil: (ringDates.last ?? Date()).addingTimeInterval(86_400))
        try await scheduler.scheduleCalendar(plan, sound: .rainyClock, soundFileNameOverride: nil,
                                             snoozeMinutes: 5, title: "Alarm", body: "Wake up")
    }

    // MARK: A ringing or snoozing alarm survives re-registration

    /// Snoozed at 7:30, the app opened at 7:31 with a stale decision: the 7:35 snooze rings.
    func testReRegisteringLeavesASnoozedAlarmToRing() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .alerting)
        alarms.move(snoozed, to: .countdown)

        let replacement = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)

        XCTAssertEqual(alarms.state(of: snoozed), .countdown)
        XCTAssertEqual(alarms.state(of: replacement), .scheduled)
    }

    func testReRegisteringLeavesARingingAlarmToRing() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let ringing = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(ringing, to: .alerting)

        try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)

        XCTAssertEqual(alarms.state(of: ringing), .alerting)
    }

    /// The states are read after the new alarm is registered, not before: an old alarm
    /// can start ringing while that call is suspended.
    func testAnAlarmThatStartsRingingDuringRegistrationIsLeftToRing() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let ringing = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.whileScheduling { alarms.move(ringing, to: .alerting) }

        try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)

        XCTAssertEqual(alarms.state(of: ringing), .alerting)
    }

    /// Undoing a skip (or turning the closure rule off) returns a weekly user to the
    /// repeating alarm while today's dated alarm snoozes.
    func testReturningToTheWeeklyAlarmLeavesASnoozedDatedAlarm() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        try await scheduleDated(scheduler, ringingAt: [Date().addingTimeInterval(3_600)])
        let dated = try XCTUnwrap(alarms.identifiers.first)
        alarms.move(dated, to: .alerting)
        alarms.move(dated, to: .countdown)

        let weekly = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        XCTAssertEqual(alarms.state(of: dated), .countdown)

        // Stopped, the one-time alarm is gone; the next pass has nothing left to cancel.
        alarms.drop(dated)
        await scheduler.retireSupersededAlarms()
        XCTAssertEqual(alarms.identifiers, [weekly])
    }

    // MARK: …and is cancelled once it is done

    /// Stopped, a replaced weekly alarm is merely scheduled again — for its next weekday,
    /// at the old time. The next pass (activation, background refresh) cancels it; while
    /// it still snoozes, that pass leaves it alone.
    func testAReplacedAlarmIsCancelledOnceItIsStopped() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .countdown)
        let replacement = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)

        await scheduler.retireSupersededAlarms()
        XCTAssertEqual(alarms.state(of: snoozed), .countdown)

        alarms.move(snoozed, to: .scheduled)
        await scheduler.retireSupersededAlarms()
        XCTAssertEqual(alarms.identifiers, [replacement])
    }

    func testADatedRegistrationLeavesASnoozedAlarmAndCancelsItOnceStopped() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .countdown)
        let tomorrow = Date().addingTimeInterval(86_400)

        try await scheduleDated(scheduler, ringingAt: [tomorrow, tomorrow.addingTimeInterval(86_400)])
        XCTAssertEqual(alarms.state(of: snoozed), .countdown)
        let dated = alarms.identifiers.subtracting([snoozed])
        XCTAssertEqual(dated.count, 2)

        alarms.move(snoozed, to: .scheduled)
        await scheduler.retireSupersededAlarms()
        XCTAssertEqual(alarms.identifiers, dated)
    }

    func testAnUnreadableListKeepsAReplacedAlarmForTheNextPass() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .countdown)
        let replacement = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)
        alarms.move(snoozed, to: .scheduled)

        alarms.setReadable(false)
        await scheduler.retireSupersededAlarms()
        alarms.setReadable(true)
        XCTAssertEqual(alarms.identifiers, [snoozed, replacement])

        await scheduler.retireSupersededAlarms()
        XCTAssertEqual(alarms.identifiers, [replacement])
    }

    /// The process stays alive and in front while the snooze is stopped from the Lock Screen:
    /// no activation follows, so the replaced weekly alarm is retired the moment the system
    /// reports it scheduled again, not at its old time next weekday (adversarial review,
    /// 2026-10-01).
    func testAReplacedAlarmIsRetiredTheMomentItIsStoppedWhileTheProcessLives() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .countdown)
        let replacement = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)

        let watching = Task { await scheduler.retireSupersededAlarmsAsTheyStop() }
        defer { watching.cancel() }
        try await waitUntil("the scheduler observes the alarm list") { alarms.isObserved }
        alarms.move(snoozed, to: .alerting)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(alarms.state(of: snoozed), .alerting, "Still ringing: left to finish")

        alarms.move(snoozed, to: .scheduled)
        try await waitUntil("the stopped alarm is retired") { alarms.identifiers == [replacement] }
    }

    // MARK: The post-registration read, the rollback and the record (adversarial review, 2026-10-01)

    /// The dated path decides from the list it reads after registering, not the one it read
    /// before: a weekly alarm that starts ringing while the dated alarms are being registered
    /// is left to ring.
    func testAnAlarmThatStartsRingingDuringADatedRegistrationIsLeftToRing() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let weekly = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.whileScheduling { alarms.move(weekly, to: .alerting) }

        try await scheduleDated(scheduler, ringingAt: [Date().addingTimeInterval(86_400)])

        XCTAssertEqual(alarms.state(of: weekly), .alerting)
        XCTAssertEqual(alarms.identifiers.count, 2)
    }

    /// The weekly path cannot read what it would replace: the new alarm is withdrawn and the
    /// old one stays, rather than two weekly alarms ringing side by side.
    func testAWeeklyRegistrationThatCannotReadTheListKeepsOnlyTheOldAlarm() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let old = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.whileScheduling { alarms.setReadable(false) }

        let ring = try XCTUnwrap(Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()))
        do {
            try await scheduler.scheduleAlarm(at: ring, normalAlarmDate: ring, weekdays: [2, 3, 4, 5, 6],
                sound: .rainyClock, soundFileNameOverride: nil, snoozeMinutes: 5, title: "Alarm", body: "Wake up")
            XCTFail("An unreadable list must fail the registration")
        } catch {}
        alarms.whileScheduling(nil)
        alarms.setReadable(true)

        XCTAssertEqual(alarms.identifiers, [old])
    }

    /// A cancel that throws is recorded and tried again by the next pass.
    func testAReplacedAlarmWhoseCancelFailedIsCancelledByTheNextPass() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let old = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.refuseCancel(of: old)
        let before = alarms.identifiers

        let ring = try XCTUnwrap(Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()))
        do {
            try await scheduler.scheduleAlarm(at: ring, normalAlarmDate: ring, weekdays: [2, 3, 4, 5, 6],
                sound: .rainyClock, soundFileNameOverride: nil, snoozeMinutes: 5, title: "Alarm", body: "Wake up")
            XCTFail("A failed cancel is reported")
        } catch {}
        let replacement = try XCTUnwrap(alarms.identifiers.subtracting(before).first)
        XCTAssertEqual(alarms.identifiers, [old, replacement])

        alarms.refuseCancel(of: nil)
        await scheduler.retireSupersededAlarms()
        XCTAssertEqual(alarms.identifiers, [replacement])
    }

    // MARK: Removing the registration while the alarm stays on (adversarial review, 2026-10-01)

    /// A new address or no repeat day left removes the registration, but the alarm is still
    /// on: a snooze in progress rings; everything merely scheduled goes; the snoozing alarm
    /// goes once it is stopped.
    func testRemovingTheRegistrationLeavesASnoozeToFinish() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .countdown)
        try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)
        try await scheduleDated(scheduler, ringingAt: [Date().addingTimeInterval(86_400)])

        await scheduler.retireScheduledAlarms()
        XCTAssertEqual(alarms.identifiers, [snoozed])
        XCTAssertEqual(alarms.state(of: snoozed), .countdown)

        alarms.move(snoozed, to: .scheduled)
        await scheduler.retireSupersededAlarms()
        XCTAssertTrue(alarms.identifiers.isEmpty)
    }

    // MARK: Turning the alarm off ends a snooze

    func testTurningTheAlarmOffEndsASnooze() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit needs iOS 26") }
        let (scheduler, alarms) = makeScheduler()
        let snoozed = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 30)
        alarms.move(snoozed, to: .countdown)
        let replacement = try await scheduleWeekly(scheduler, alarms, hour: 7, minute: 0)
        alarms.move(replacement, to: .countdown)

        await scheduler.cancelScheduledAlarms()

        XCTAssertTrue(alarms.identifiers.isEmpty)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting until \(what)", file: file, line: line)
    }
}
#endif
