import Foundation

enum AppEnvironment {
    static var routeWeatherService: any RouteWeatherService {
        #if DEBUG
        MockRouteWeatherService()
        #else
        MapKitRouteWeatherService()
        #endif
    }

    static var usesWeatherKit: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
}
