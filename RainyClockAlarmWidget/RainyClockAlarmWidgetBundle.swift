import SwiftUI
import WidgetKit

@main
struct RainyClockAlarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommuteAlarmLiveActivity()
        TomorrowAlarmWidget()
    }
}
