import SwiftUI

@main
struct JackWeatherClockApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: AlarmViewModel())
        }
    }
}
