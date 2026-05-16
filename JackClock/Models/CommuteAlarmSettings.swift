import Foundation

struct CommuteAlarmSettings: Equatable {
    var homeAddress: String = ""
    var workAddress: String = ""
    var alarmTime: Date = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    var rainLeadTimeMinutes: Int = 30
}

struct RouteWeatherSnapshot: Equatable {
    var checkedAt: Date
    var segments: [RouteWeatherSegment]

    var hasRain: Bool {
        segments.contains { $0.condition == .rain }
    }
}

struct RouteWeatherSegment: Identifiable, Equatable {
    enum Condition: String, Equatable {
        case clear
        case cloudy
        case rain
    }

    var id = UUID()
    var name: String
    var condition: Condition
    var precipitationProbability: Double
}

struct ScheduledAlarmSummary: Equatable {
    var normalAlarmDate: Date
    var scheduledAlarmDate: Date
    var rainDetected: Bool
    var leadTimeMinutes: Int
}
