# Jack Clock

Jack Clock is an iOS alarm app concept that adjusts a commute alarm when rain is detected along the route between home and work.

## Goal

The user enters:

- Home address
- Work address
- Normal alarm time
- Rain lead time, for example 30 minutes
- Rain probability threshold

The app evaluates the driving commute route. If the rain probability on any route segment meets or exceeds the user's threshold, it schedules the alarm earlier by the configured lead time.

## Current Status

- SwiftUI iOS app skeleton
- Address, alarm time, and rain lead-time settings
- User-configurable rain probability threshold
- Local notification scheduling
- Mock route weather service for end-to-end UI flow
- Service protocols prepared for MapKit and WeatherKit integration

## Next Technical Milestones

1. Replace `MockRouteWeatherService` with a MapKit route provider.
2. Sample weather along driving-route coordinates with WeatherKit.
3. Add background refresh or server push strategy for checking weather at the configured lead-time point.
4. Add persistence for commute profiles.
5. Add unit tests for probability threshold and alarm-time adjustment edge cases.

## Open Product Questions

- Should weather refresh be handled locally with BGTaskScheduler, or reliably through a lightweight server and push notification?
- Should heavy rain add more time than light rain in a later version?
