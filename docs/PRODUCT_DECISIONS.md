# Product Decisions

## Initial Scope

The first version focuses on one commute profile: home to work. Users can set a normal alarm time and a rain lead time. If the route weather service reports rain on any segment, the app schedules the alarm earlier.

## Weather Strategy

The app is structured around a `RouteWeatherService` protocol. The current implementation is a mock so the app can be built and exercised before API credentials and Apple entitlements are configured.

The production implementation should:

1. Geocode home and work addresses.
2. Request candidate routes from MapKit.
3. Sample representative coordinates along the selected route.
4. Query WeatherKit for each sample around the commute window.
5. Return whether any segment has rain above the chosen threshold.

## Alarm Strategy

Local notifications are scheduled through `UNUserNotificationCenter`. If the adjusted alarm time has already passed today, it rolls forward to tomorrow.

## Design Questions

- Do users need separate weekday/weekend schedules?
- Should the app allow multiple workplaces or saved profiles?
- Should heavy rain add more time than light rain?
- Should the route be chosen automatically, or should users pick among route options?
