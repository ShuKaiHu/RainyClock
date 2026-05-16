# Product Decisions

## Initial Scope

The first version focuses on one commute profile: home to work. Users can choose a commute mode, set a normal alarm time, a rain lead time, and a rain probability threshold. If any route segment meets or exceeds that threshold, the app schedules the alarm earlier.

## Weather Strategy

The app is structured around a `RouteWeatherService` protocol. The current implementation is a mock so the app can be built and exercised before API credentials and Apple entitlements are configured.

The production implementation should:

1. Geocode home and work addresses.
2. Request routes for the selected commute mode.
3. Sample representative coordinates along the selected route.
4. Query WeatherKit for each sample around the commute window.
5. Return whether any segment meets or exceeds the chosen rain probability threshold.

## Alarm Strategy

Local notifications are scheduled through `UNUserNotificationCenter`. If the adjusted alarm time has already passed today, it rolls forward to tomorrow.

The intended product behavior is to refresh weather at the configured lead-time point. For example, if the normal alarm is 7:30 and the rain lead time is 30 minutes, the app should check the selected route at 7:00. If the threshold is exceeded, the early alarm fires immediately; otherwise, the normal 7:30 alarm remains.

iOS does not guarantee exact background execution at a specific minute for third-party apps. A production implementation needs one of these strategies:

- Local-first: schedule a normal alarm and request a `BGAppRefreshTask` around the lead-time point, accepting that iOS may delay or skip the refresh.
- Server-backed: store the commute check server-side, evaluate weather at the lead-time point, and send a push notification if the early alarm should fire.

## Design Questions

- Do users need separate weekday/weekend schedules?
- Should the app allow multiple workplaces or saved profiles?
- Should heavy rain add more time than light rain?
- Should the route be chosen automatically, or should users pick among route options?
- Should scooter mode use MapKit automotive routing as a first approximation, or a Taiwan-specific route provider?
