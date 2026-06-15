import Foundation

struct CommuteAlarmSettings: Codable, Equatable {
    static let allWeekdays = Set(1...7)

    enum CommuteMode: String, CaseIterable, Codable, Identifiable, Equatable {
        case car
        case scooter
        case walking
        case publicTransit

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .car:
                String(localized: "commute_mode_car")
            case .scooter:
                String(localized: "commute_mode_scooter")
            case .walking:
                String(localized: "commute_mode_walking")
            case .publicTransit:
                String(localized: "commute_mode_public_transit")
            }
        }
    }

    enum AlarmSound: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
        case rainyClock
        case morningBell
        case softPiano
        case systemDefault

        static var allCases: [AlarmSound] {
            [.rainyClock, .morningBell, .softPiano]
        }

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rainyClock:
                String(localized: "alarm_sound_rainy_clock")
            case .morningBell:
                String(localized: "alarm_sound_morning_bell")
            case .softPiano:
                String(localized: "alarm_sound_soft_piano")
            case .systemDefault:
                String(localized: "alarm_sound_system_default")
            }
        }

        var fileName: String {
            switch self {
            case .rainyClock:
                "RainyClock.wav"
            case .morningBell:
                "MorningBell.wav"
            case .softPiano:
                "SoftPiano.wav"
            case .systemDefault:
                "AlarmTone.wav"
            }
        }
    }

    var homeAddress: String = ""
    var workAddress: String = ""
    var commuteMode: CommuteMode = .car
    var alarmTime: Date = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    var rainLeadTimeMinutes: Int = 30
    var rainProbabilityThreshold: Double = 0.5
    var selectedWeekdays: Set<Int> = Self.allWeekdays
    var alarmSound: AlarmSound = .rainyClock

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        homeAddress = try values.decodeIfPresent(String.self, forKey: .homeAddress) ?? ""
        workAddress = try values.decodeIfPresent(String.self, forKey: .workAddress) ?? ""
        commuteMode = try values.decodeIfPresent(CommuteMode.self, forKey: .commuteMode) ?? .car
        alarmTime = try values.decodeIfPresent(Date.self, forKey: .alarmTime)
            ?? Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date())
            ?? Date()
        rainLeadTimeMinutes = try values.decodeIfPresent(Int.self, forKey: .rainLeadTimeMinutes) ?? 30
        rainProbabilityThreshold = try values.decodeIfPresent(Double.self, forKey: .rainProbabilityThreshold) ?? 0.5
        selectedWeekdays = try values.decodeIfPresent(Set<Int>.self, forKey: .selectedWeekdays) ?? Self.allWeekdays
        let decodedAlarmSound = try values.decodeIfPresent(AlarmSound.self, forKey: .alarmSound) ?? .rainyClock
        alarmSound = decodedAlarmSound == .systemDefault ? .rainyClock : decodedAlarmSound
    }
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
    enum Condition: String, Equatable, Sendable {
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
