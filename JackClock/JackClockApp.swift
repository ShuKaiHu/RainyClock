import SwiftUI

@main
struct JackClockApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: AlarmViewModel())
        }
    }
}
