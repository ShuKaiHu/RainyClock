# Rainy Clock — where to look

Two platforms, two logs. iOS and Android ship on different schedules and are often worked on
at the same time, so each keeps its own history, backlog and "where were we?":

- **iPhone app** → **`docs/STATUS-IOS.md`**
- **Android port** → **`docs/STATUS-ANDROID.md`**

Write platform state into its own log, never into this page. Split on 2026-08-09 after one
shared file kept collecting both platforms' edits from two sessions at once. Only facts that
are true of *both* belong here.

The same split now exists on disk: **one git worktree per platform**, one branch each, so the
two sessions no longer share a working tree either. `RainyClock-iOS/` is iOS on
`ios/main`; `RainyClock-Android/` beside it is Android on
`claude/android-play-store-release-jykw59`. `git worktree list` confirms it. Both checkouts
hold the whole repo — the separation is by branch, not by directory.

## Where things stand — 2026-08-13

| Platform | State |
| --- | --- |
| **iOS** | `1.7.1 (37)` live on the App Store since 2026-09-26 (TW and US storefronts): RainyClock Plus membership (monthly subscription + one-time purchase), Unity LevelPlay ads, address suggestions. 1.8.0 (40) was submitted for review on 2026-10-03 00:14 and is Waiting for Review, manual release (38 and 39 went to TestFlight on 2026-10-02; 39 adds today's weather on the medium widget; 40, the submitted build, raises the app's closure-feed freshness limit from 15 minutes to one hour, because the day-off service has polled every 30 minutes since 2026-10-02, and makes the small widget draw the same forecast sky as the medium, with the Apple Weather mark): typhoon day-off, the master alarm switch and the "Next Alarm" Home/Lock Screen widget (`ios/widget` merged into the 1.8.0 line on 2026-10-01). |
| **Android** | Never shipped. The port builds, runs and matches the iOS behaviour, but a weather-provider licensing call and a Play developer account still block a first release. |

## Shared references

- Voice-classification backend migration, deployed 2026-09-16 (Gemini 3.1 Flash-Lite on Vertex;
  existing Cloud TTS voices retained) → [verification, samples and rollback](annotation-migration-2026-09-16/README.md)
- Product reasoning and rejected alternatives, both platforms → `docs/PRODUCT_DECISIONS.md`
- Day-off suppression (typhoon 停班停課 + 國定假日), both platforms → `docs/DAYOFF-SPEC.md`,
  with `docs/dayoff-fixtures.json` (the contract) and `docs/dayoff-corpus-summary.json` (the evidence)
- iOS submission mechanics, rejection history, AdMob and app-ads.txt → `docs/app-store-submission-checklist.md`
- iOS store copy, release notes, review notes → `docs/appstore-metadata.md`
- Android architecture and platform substitutions → `docs/ANDROID.md`
- Play Store runbook → `docs/play-store-submission-checklist.md`

## True on both sides

- **The published website is this repo.** `docs/` is served at `shukaihu.github.io/RainyClock/`
  and carries the support and privacy-policy pages linked from the live App Store listing —
  and the privacy-policy page is what a Play listing will have to point at too. **This repo
  must stay public**, and a fix to either page only counts once it is pushed. The domain root
  and `app-ads.txt` come from a *different* repo, `ShuKaiHu/ShuKaiHu.github.io`.
- **`app-ads.txt` is per AdMob account, not per app.** It is already verified, so an Android
  app registered under the same account needs no change to it.
- **The alarm tones are shared.** Android copies the iOS target's `.wav` files at build time
  rather than duplicating them; deleting one on the iOS side breaks the Android build.
- **Day-off suppression is specified once, for both platforms.** `docs/DAYOFF-SPEC.md` (spec v4,
  2026-10-01; iOS implemented it behind a release gate, Android not started) and `docs/dayoff-fixtures.json` beside it define
  when a typhoon 停班停課 announcement or a national holiday silences the alarm. The fixtures — 28
  real DGPA sentence patterns and 25 decision scenarios, drawn from the complete 1,374-alert
  archive (2014-2026) — are the actual contract: both platforms load them in unit tests, so a rule
  change on one side surfaces as a failing test on the other rather than as two implementations
  that quietly disagree during a typhoon. Changing behaviour means editing the fixtures and bumping
  `specVersion`; each platform records the version it has implemented in its own status log. Read
  §0 of the spec before touching either file.
