# App Store Submission Checklist / App Store 送審清單

## Status / 狀態

| Area | Status | Notes |
|------|--------|-------|
| App binary | Mostly ready | Debug/simulator build passes. Need Release archive upload. |
| Bundle ID | Ready | `com.shukaihu.RainyClock` |
| Version | Ready | `1.0` build `1` |
| Category | Ready | Utilities |
| App icon | Needs visual review | 1024x1024 icon exists; final branding still needs approval. |
| Privacy policy | Draft ready | `docs/privacy-policy.html`; needs public URL and real contact email. |
| Support page | Draft ready | `docs/support.html`; needs public URL and real contact email. |
| App Store metadata | Draft ready | `docs/appstore-metadata.md`; needs final URLs, copyright, price. |
| Screenshots | Missing | Need current screenshots for route tab, alarm tab, and scheduled result. |
| TestFlight | Not uploaded | Need Xcode Archive → Distribute App → App Store Connect upload. |
| WeatherKit | Needs production verification | Release build must be tested with paid Developer Team and WeatherKit capability. |
| App Review notes | Draft ready | Included in `docs/appstore-metadata.md`. |

## You Need To Provide / 需要你提供

1. Public URLs
   - Privacy policy URL: `https://shukaihu.github.io/RainyClock/privacy-policy.html`
   - Support URL: `https://shukaihu.github.io/RainyClock/support.html`

2. Support contact
   - Public support email address.
   - Optional: legal address or phone number if you want it on the support page.

3. Copyright owner
   - Example: `2026 Shu-Kai Hu`
   - If publishing under a company, provide the legal company name.

4. Price
   - Free for first release is recommended.
   - If paid, decide App Store price tier.

5. Screenshots
   - Route tab with sample home/work addresses and route preview.
   - Alarm tab with weekday/time/rain settings.
   - Scheduled result with route weather cards.
   - English and Traditional Chinese screenshots if both localizations are submitted.

6. Final app icon approval
   - Current icon exists technically.
   - Confirm whether the current visual is final enough for App Store.

## App Store Connect Fields / App Store Connect 欄位

### App Information

- Name: `Rainy Clock`
- Subtitle: `Rain-aware alarm for commuters`
- Bundle ID: `com.shukaihu.RainyClock`
- SKU: `rainyclock-1`
- Primary Category: `Utilities`
- Content Rating: expected `4+`
- Price: TODO

### Version Information

- Version: `1.0`
- Promotional text: prepared in `docs/appstore-metadata.md`
- Description: prepared in `docs/appstore-metadata.md`
- Keywords: prepared in `docs/appstore-metadata.md`
- Support URL: TODO public URL
- Marketing URL: optional
- Copyright: TODO

### App Privacy

Recommended conservative answers:

- No tracking.
- No analytics.
- No advertising.
- Precise location/address use only for app functionality.
- Data is not linked to the user by the developer.

### Export Compliance

The app does not implement custom encryption. It only uses Apple platform networking/services. The Xcode project declares `ITSAppUsesNonExemptEncryption = NO` so App Store Connect should not repeatedly ask for non-exempt encryption documentation.

## Pre-Submission QA / 送審前測試

1. Install Release build on a real iPhone.
2. Confirm notification permission prompt appears.
3. Enter real home/work addresses.
4. Confirm route preview loads.
5. Confirm route weather cards update with Apple Weather attribution.
6. Schedule an alarm one or two minutes ahead.
7. Confirm local notification arrives and custom sound plays.
8. Test English and Traditional Chinese UI.
9. Test no-network behavior does not crash.
10. Confirm App Store screenshots match the current UI.

## Known Review Risks / 送審風險

1. Alarm reliability
   - iOS local notifications are allowed, but third-party apps cannot behave exactly like Apple's Clock app full-screen alarm.
   - App Review notes should describe this as a smart notification alarm.

2. WeatherKit entitlement
   - Release builds need WeatherKit enabled for the Bundle ID in Apple Developer.
   - If entitlement is missing, route weather will fail in production.

3. Scooter routing
   - Scooter mode currently uses app-level mode labeling; Apple Maps may not provide Taiwan-specific scooter-road restrictions.
   - Avoid over-promising scooter-specific legal routing in App Store text.

4. Support URL
   - Apple requires a support URL with actual contact information.
   - Do not submit until `docs/support.html` is hosted publicly and contact info is real.
