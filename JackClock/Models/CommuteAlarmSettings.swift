import Foundation

struct CommuteAlarmSettings: Equatable {
    enum CommuteMode: String, CaseIterable, Identifiable, Equatable {
        case car
        case scooter
        case walking
        case publicTransit

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .car:
                "Car"
            case .scooter:
                "Scooter"
            case .walking:
                "Walking"
            case .publicTransit:
                "Public Transit"
            }
        }
    }

    var homeAddress: String = ""
    var workAddress: String = ""
    var commuteMode: CommuteMode = .car
    var alarmTime: Date = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    var rainLeadTimeMinutes: Int = 30
    var rainProbabilityThreshold: Double = 0.5
}

struct RouteWeatherSnapshot: Equatable {
    var checkedAt: Date
    var segments: [RouteWeatherSegment]

    func exceedsRainThreshold(_ threshold: Double) -> Bool {
        segments.contains { $0.precipitationProbability >= threshold }
    }

    var maximumPrecipitationProbability: Double {
        segments.map(\.precipitationProbability).max() ?? 0
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
    var weatherRefreshDate: Date
    var exceedsRainThreshold: Bool
    var leadTimeMinutes: Int
    var rainProbabilityThreshold: Double
    var maximumPrecipitationProbability: Double
}
