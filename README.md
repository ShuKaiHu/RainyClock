# Jack Clock

Jack Clock is an iOS alarm app concept that adjusts a commute alarm when rain is detected along the route between home and work.

## Goal

The user enters:

- Home address
- Work address
- Normal alarm time
- Rain lead time, for example 30 minutes

The app evaluates the commute route. If rain is expected on any route segment, it schedules the alarm earlier by the configured lead time.

## Current Status

- SwiftUI iOS app skeleton
- Address, alarm time, and rain lead-time settings
- Local notification scheduling
- Mock route weather service for end-to-end UI flow
- Service protocols prepared for MapKit and WeatherKit integration

## Next Technical Milestones

1. Replace `MockRouteWeatherService` with a MapKit route provider.
2. Sample weather along route coordinates with WeatherKit.
3. Add persistence for multiple commute profiles.
4. Add background refresh strategy and notification rescheduling.
5. Add unit tests for alarm-time adjustment edge cases.

## Open Product Questions

- Should the app check weather once when the alarm is created, or refresh shortly before wake-up?
- Should rain on any segment trigger the lead time, or only rain above a configurable probability/intensity?
- Should the route mode support driving, transit, walking, or all of them?
