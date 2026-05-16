import Foundation

enum AlarmTimeCalculator {
    static func nextAlarmDate(
        alarmTime: Date,
        leadTimeMinutes: Int,
        shouldApplyLeadTime: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledAlarmSummary {
        let timeComponents = calendar.dateComponents([.hour, .minute], from: alarmTime)
        let normalToday = calendar.date(
            bySettingHour: timeComponents.hour ?? 7,
            minute: timeComponents.minute ?? 30,
            second: 0,
            of: now
        ) ?? now

        let normalAlarmDate = normalToday > now
            ? normalToday
            : calendar.date(byAdding: .day, value: 1, to: normalToday) ?? normalToday

        let scheduledAlarmDate = shouldApplyLeadTime
            ? calendar.date(byAdding: .minute, value: -leadTimeMinutes, to: normalAlarmDate) ?? normalAlarmDate
            : normalAlarmDate

        return ScheduledAlarmSummary(
            normalAlarmDate: normalAlarmDate,
            scheduledAlarmDate: scheduledAlarmDate,
            rainDetected: shouldApplyLeadTime,
            leadTimeMinutes: shouldApplyLeadTime ? leadTimeMinutes : 0
        )
    }
}
