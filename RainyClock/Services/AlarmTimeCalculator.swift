import Foundation

enum AlarmTimeCalculator {
    static func nextAlarmDate(
        alarmTime: Date,
        leadTimeMinutes: Int,
        shouldApplyLeadTime: Bool,
        rainProbabilityThreshold: Double,
        maximumPrecipitationProbability: Double,
        selectedWeekdays: Set<Int> = CommuteAlarmSettings.allWeekdays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledAlarmSummary {
        let timeComponents = calendar.dateComponents([.hour, .minute], from: alarmTime)
        let selectedWeekdays = selectedWeekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : selectedWeekdays
        let normalAlarmDate = nextDate(
            hour: timeComponents.hour ?? 7,
            minute: timeComponents.minute ?? 30,
            selectedWeekdays: selectedWeekdays,
            after: now,
            calendar: calendar
        )

        let leadTimeDate = calendar.date(byAdding: .minute, value: -leadTimeMinutes, to: normalAlarmDate) ?? normalAlarmDate
        let scheduledAlarmDate = shouldApplyLeadTime
            ? max(leadTimeDate, now)
            : normalAlarmDate

        return ScheduledAlarmSummary(
            normalAlarmDate: normalAlarmDate,
            scheduledAlarmDate: scheduledAlarmDate,
            weatherRefreshDate: leadTimeDate,
            exceedsRainThreshold: shouldApplyLeadTime,
            leadTimeMinutes: shouldApplyLeadTime ? leadTimeMinutes : 0,
            rainProbabilityThreshold: rainProbabilityThreshold,
            maximumPrecipitationProbability: maximumPrecipitationProbability
        )
    }

    private static func nextDate(
        hour: Int,
        minute: Int,
        selectedWeekdays: Set<Int>,
        after now: Date,
        calendar: Calendar
    ) -> Date {
        let todayStart = calendar.startOfDay(for: now)

        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: todayStart),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
                continue
            }

            guard candidate > now else {
                continue
            }

            if selectedWeekdays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }

        return now
    }
}
