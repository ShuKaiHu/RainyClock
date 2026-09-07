# Rainy Clock App Store Metadata

> **English (U.S.) was added with the `1.6.4 (19)` submission** and goes live when that version is released. Two gotchas discovered while adding it on 2026-07-29: (1) the English app names "Rainy Clock" and "RainyClock" are **taken by other accounts**, so the English listing name is `Rainy Clock: Rain Alarm`; (2) App Store Connect's version page has a UI bug — when adding a localization fails (e.g. because of the name conflict), the 儲存 button just shows a red error icon with no message and retries a doomed create forever. The real error is only visible on the `POST /iris/v1/appStoreVersionLocalizations` response (409). The workaround that worked: create the `appInfoLocalizations` record (name + subtitle) via the iris API from the logged-in browser session, then PATCH the auto-created `appStoreVersionLocalizations` with the copy below.
>
> **Re-checked 2026-08-13:** English "Rainy Clock" is still taken — `PATCH /iris/v1/appInfoLocalizations` returns 409. The App 資訊 page now shows a proper inline error for this (the silent-red-icon bug seems specific to the version page), including a name-release request link (`apple.com/legal/internet-services/itunes/appnamenotices/`) — trademark holders only, so not an option for us. No live app anywhere uses the name; it is squatted by an unreleased app. The **繁體中文 name had actually been live as `RainyClock` (no space)**, not `Rainy Clock` as this table used to claim; renamed to `Rainy Clock` in ASC on 2026-08-13, publishing with the next release. Same day, the English name was changed to **`Rainy-Clock`** (hyphen) — that variant was accepted, so the squat covers only the exact strings "Rainy Clock"/"RainyClock". The `: Rain Alarm` suffix is gone; "rain alarm" stays in the keyword field either way.

## App Information

| Field | English | 繁體中文 |
| --- | --- | --- |
| App Name | Rainy-Clock（1.6.5 以前是 Rainy Clock: Rain Alarm）| Rainy Clock（1.6.5 以前是 RainyClock，無空格）|
| Subtitle | Rain-aware commute alarm | 雨天鬧鐘 |
| Category | Weather | 天氣 |
| Secondary Category | Utilities | 工具程式 |
| Price | Free | 免費 |
| Copyright | 2026 Shu-Kai Hu | 2026 Shu-Kai Hu |
| Support URL | `https://shukaihu.github.io/RainyClock/support.html` | `https://shukaihu.github.io/RainyClock/support.html` |
| Privacy Policy URL | `https://shukaihu.github.io/RainyClock/privacy-policy.html` | `https://shukaihu.github.io/RainyClock/privacy-policy.html` |
| Marketing URL | `https://shukaihu.github.io/RainyClock/` | `https://shukaihu.github.io/RainyClock/` |

The marketing URL is what the ad network reads to locate `app-ads.txt` — AdMob used to, Unity LevelPlay does now; it must stay on the `shukaihu.github.io` domain. See the app-ads.txt section of `docs/app-store-submission-checklist.md`.

## Promotional Text

### English

Rainy Clock checks your commute weather and helps schedule an earlier alarm when rain may slow you down.

### 繁體中文

雨天鬧鐘會檢查通勤天氣，當雨勢可能影響出門時間時，協助你提前安排鬧鐘。

## Description

### English

Rainy Clock is a smart alarm app built for commuters.

Set your home and work addresses, choose a commute mode, then set your normal alarm time. Rainy Clock previews your commute route and checks Apple Weather around your home and office. When the rain chance exceeds your threshold, it moves your alarm earlier — so rainy mornings never catch you off guard.

Key features:
- Alarm breaks through Silent mode and Focus with a full-screen alert (iOS 26 and later)
- Snooze you can turn on or off, with a 1–15 minute interval and a countdown on the Lock Screen and in the Dynamic Island (iOS 26 and later)
- Home and work address setup with Apple Maps route preview
- Weather checks powered by Apple Weather
- Adjustable rain lead time and rain probability threshold
- Weekday alarm selection
- Built-in alarm sounds with preview, plus the system default alarm tone on iOS 26 and later
- Any settings change syncs to the scheduled alarm automatically

On iOS 17–25, alarms are scheduled as local notifications and still follow the silent switch.

Rainy Clock does not require an account and does not run its own backend server.

### 繁體中文

雨天鬧鐘是一款為通勤族設計的智慧鬧鐘 App。

設定住家與工作地址、選擇通勤方式，再設定平常的鬧鐘時間。雨天鬧鐘會預覽你的通勤路線，並透過 Apple Weather 檢查住家與公司附近的天氣。如果降雨機率超過你設定的門檻，App 會自動把鬧鐘提前，讓雨天早晨更從容。

主要功能：
・鬧鐘穿透靜音與專注模式，以全螢幕提示響鈴（iOS 26 以上）
・賴床功能可開關，間隔 1 到 15 分鐘自由選擇，倒數會顯示在鎖定畫面與動態島（iOS 26 以上）
・設定住家與工作地址，使用 Apple Maps 預覽通勤路線
・透過 Apple Weather 檢查天氣
・可調整雨天提前時間與降雨機率門檻
・可選擇鬧鐘響鈴的星期
・內建多種鬧鈴音效並支援試聽，iOS 26 以上還可選擇系統預設鬧鈴
・調整任何設定後，已排程的鬧鐘會自動同步更新

iOS 17–25 以本機通知排程鬧鐘，響鈴仍會受靜音開關影響。

雨天鬧鐘不需要註冊帳號。你輸入的 AI 語音台詞會送到我們的轉發服務並交給 Google 合成，其餘資料都留在裝置上。

## Keywords

### English

rain alarm,weather alarm,commute alarm,smart alarm,rain,weather,alarm clock,commute

### 繁體中文

雨天鬧鐘,天氣鬧鐘,通勤鬧鐘,智慧鬧鐘,降雨,天氣,鬧鐘,通勤

## Version 1.6.9 (28) “What’s New”

One new feature — the evening-before preview — leads; the ad-control move and the quota
change follow because they are true and small. Nothing invented.

### English

```
Know tonight what tomorrow's alarm will do.

• Evening preview: the night before an alarm, at a time you choose, Rainy Clock tells you where on your route rain is likely, how likely, whether that moves the alarm earlier, and when the forecast was checked. If your phone cannot update forecasts in the background, it says so, so you can open the app. Tap "Send a preview" to see one right away, or switch it off under Snooze in the Alarm tab.
• "Report an ad" and the ad privacy options now sit together at the bottom of the Alarm tab, out of the alarm settings.
• A report link also appears right under the banner, and the report now says which ad it is about so it can actually be traced and blocked.
• Your voice-alarm generations, including ones earned by watching a video, now stay with your phone through a reinstall.
```

### 繁體中文

```
前一晚就知道明早鬧鐘會不會提前。

• 前一晚預告：有鬧鐘的前一晚，在你選的時間，雨天鬧鐘會通知你路上哪一段降雨機率多高、有沒有超過你設的門檻、鬧鐘會不會提前，以及預報是什麼時候查的。如果手機目前無法在背景更新預報，也會直接告訴你，讓你開一下 App。按「先看一則」可以馬上看到長什麼樣子；不想收到的話，鬧鐘分頁的賴床設定下方可以關掉。
• 「檢舉廣告」和廣告隱私設定現在一起放在鬧鐘分頁的最下方，不再混在鬧鐘設定裡。
• 橫幅廣告下方也多了檢舉入口，而且檢舉內容現在會註明是哪一則廣告，方便追查與封鎖。
• 語音鬧鐘的生成次數（包括看影片換到的）現在會跟著手機保留，重新安裝也不會遺失。
```

## Version 1.6.8 (27) “What’s New”

The AI voice alarm. Written to say what the user gets and what it costs them, because the
free-then-watch-an-ad shape is the part they need to understand before tapping into it.

### English

```
Wake up to a voice instead of a tone.

• Write what your alarm should say, pick one of six voices, and Rainy Clock speaks it. The delivery varies across your sentences on its own — warmer at the start, more urgent about the weather, encouraging at the end.
• Listen to every voice before choosing. Previews are built in, cost nothing, and work offline.
• The first three you make are free. After that, watching a short video earns one more.
• Your finished alarm is saved on your phone and rings even without a connection.
```

### 繁體中文

```
用人聲叫你起床，不再只是鈴聲。

• 寫下你想聽到的話，選一個聲音，雨天鬧鐘會唸出來。語氣會依句子自己變化——開頭溫和一點、講到天氣時比較急、結尾帶點鼓勵。
• 六個聲音都可以先試聽。試聽內建在 App 裡，不花次數也不需要網路。
• 前三次免費。之後每看一段短片可以再做一次。
• 做好的鬧鈴存在手機上，沒有網路也照樣會響。
```

## Version 1.6.7 “What’s New”

The ad provider changed and nothing else did, so these notes say that plainly rather than
inventing user-facing changes — the same rule `1.6.2` followed. `1.6.6` did clear review and
went live 2026-08-18, so `1.6.7 (26)` is the right pair; build 26 was uploaded 2026-08-30.

### English

```
A behind-the-scenes change to advertising:

• Rainy Clock now works with a different advertising provider. Nothing about the app itself changes — alarms, commute routes, and weather work exactly as before.
• In the European Economic Area, the UK, and Switzerland, the ad consent question is now asked by Rainy Clock itself, so it appears once more after this update. It can still be changed at any time from "Ad privacy options" in Settings.
```

### 繁體中文

```
廣告投放方式的幕後更新：

• 雨天鬧鐘改用另一家廣告服務商。App 本身完全不變——鬧鐘、通勤路線與天氣功能維持原樣。
• 歐洲經濟區、英國與瑞士的廣告同意選項改由雨天鬧鐘自行詢問，因此更新後會再出現一次。之後仍可隨時在設定的「廣告隱私設定」中重新調整。
```

## Version 1.6.6 (24) “What’s New”

`1.6.5` is live (released 2026-08-04), so these notes cover **only what is new since it** —
they must not repeat the round weekday buttons or the ads question, which users already have.

### English

```
Rain checks along your whole route:

• Rainy Clock now checks the forecast at points along your commute, not only at home and the office. If rain is expected anywhere on the way, your alarm still moves earlier.
• Route weather now names each point by where it is — halfway, a quarter of the way — instead of numbering them.
• Larger text is properly supported. With a bigger system font size, the weekday buttons and the transport options no longer cut their labels off.
```

### 繁體中文

```
整段通勤路線都查雨：

• 雨天鬧鐘現在會查詢通勤途中各點的預報，不再只看住家和公司。路上任何一段預報會下雨，鬧鐘一樣提前叫你。
• 路線天氣改用位置標示每個查詢點（路程一半、路程 ¼），不再只是編號。
• 完整支援放大字級。系統字體調大時，星期按鈕與交通方式的文字不會再被截掉。
```

## Version 1.6.5 (22) “What’s New”

`1.6.4` was rejected before release, so these notes carry its interface changes as well — from
a user's point of view `1.6.5` is the version where both land.

### English

```
Interface refresh, plus a say over your ads:

• The weekday selector on the Alarm tab now uses round buttons — the days your alarm will ring are clearly highlighted with a blue circle, visible at a glance.
• One consistent blue across the whole app: the sound preview, snooze switch, schedule button, and transport mode selector now share the same accent color.
• Each alarm morning is now decided on its own forecast: Rainy Clock re-checks the weather before every scheduled day, so an alarm moves earlier only on the mornings rain is actually expected.
• You are now asked whether ads may be matched to your interests. Decline and the app works exactly the same — you just see less relevant ads.
```

### 繁體中文

```
介面更新，並讓你決定廣告要不要個人化：

• 鬧鐘頁的星期選擇改為圓形按鈕——鬧鐘會響的日子以藍色圓底清楚標示，一眼就能看出來。
• 統一整個 App 的介面色彩：鈴聲試聽、賴床開關、排程按鈕與交通方式選擇現在使用同一個藍色。
• 每個鬧鐘日都會依當天的預報決定：雨天鬧鐘會在每個排程日前重新查詢天氣，只有真的預報會下雨的早晨才提前響。
• 新增詢問是否允許廣告依你的興趣呈現。選擇不允許也不影響任何功能，只是看到的廣告關聯性較低。
```

## Version 1.6.4 (19) “What’s New”

Rejected before release; superseded by the 1.6.5 notes above.

### English

```
Interface refresh:

• The weekday selector on the Alarm tab now uses round buttons — the days your alarm will ring are clearly highlighted with a blue circle, visible at a glance.
• One consistent blue across the whole app: the sound preview, snooze switch, schedule button, and transport mode selector now share the same accent color.
```

### 繁體中文

```
介面更新：

• 鬧鐘頁的星期選擇改為圓形按鈕——鬧鐘會響的日子以藍色圓底清楚標示，一眼就能看出來。
• 統一整個 App 的介面色彩：鈴聲試聽、賴床開關、排程按鈕與交通方式選擇現在使用同一個藍色。
```

## Version 1.6.3 (18) “What’s New”

### English

```
Your alarm now rings even on silent.

• On iOS 26 and later, the alarm uses Apple's new alarm system: it breaks through Silent mode and Focus with a full-screen alert, just like the built-in Clock app.
• New Snooze options: turn snooze on or off and pick an interval from 1 to 15 minutes. While snoozing, a countdown appears on the Lock Screen and in the Dynamic Island.
• New "System Default Alarm" ringtone option (iOS 26 and later).
• Changing the alarm time, weekdays, rain settings, sound, or snooze now updates the scheduled alarm automatically — no need to press the button again. Changing an address removes the alarm so you can confirm the new route first.
• The status message now clearly shows in color whether an alarm is currently set.

On iOS 17–25, alarms still follow the silent switch; the snooze interval controls how often the alarm re-rings until you stop it.
```

### 繁體中文

```
鬧鐘現在連靜音時也會響。

• 在 iOS 26 以上，鬧鐘改用 Apple 全新的系統鬧鐘機制：如同內建時鐘 App，以全螢幕提示穿透靜音與專注模式。
• 新增賴床選項：可開關賴床並選擇 1 到 15 分鐘的間隔；賴床倒數會顯示在鎖定畫面與動態島。
• 新增「系統預設鬧鈴」鈴聲選項（iOS 26 以上）。
• 調整鬧鐘時間、星期、雨天設定、鈴聲或賴床後，已排程的鬧鐘會自動同步更新，不需再按一次按鈕；變更地址則會先移除鬧鐘，確認新路線後再重新排程。
• 按鈕下方的狀態訊息改以顏色清楚顯示目前是否已設定鬧鐘。

iOS 17–25 的鬧鐘仍受靜音開關影響；賴床間隔會決定鬧鐘在停止前重複響鈴的頻率。
```

## Version 1.6.2 (17) “What’s New”

Submitted 2026-07-27. Nothing in this release is visible outside the EEA, the UK, and Switzerland; the notes say so rather than inventing user-facing changes.

### English

```
This update focuses on advertising privacy:

• In the European Economic Area, the UK, and Switzerland, a consent choice now appears before any ads load, and it can be changed at any time from "Ad privacy options" in Settings.
• Updated the technical configuration used for ad measurement.

Everywhere else the experience is unchanged — alarms, commute routes, and weather work exactly as before.
```

### 繁體中文

```
本次更新著重於廣告隱私規範：

• 歐洲經濟區、英國與瑞士的使用者，開啟 App 時會先看到廣告用途的同意選項，之後可隨時在設定中的「廣告隱私設定」重新調整。
• 更新廣告成效評估所需的技術設定。

其他地區的使用體驗不變，鬧鐘、通勤路線與天氣功能維持原樣。
```

## Version 1.3 “What’s New”

### English

- Improved address validation and route preview handling.
- Updated route weather checks to use Apple Weather.
- Added clearer actual-address hints when a typed address resolves to a suggested location.
- Refined alarm lead-time controls and route/alarm layout.

### 繁體中文

- 改善地址驗證與路線預覽處理。
- 路線天氣改用 Apple Weather。
- 當輸入地址被解析為建議地點時，顯示更清楚的實際使用地址提示。
- 調整雨天提前時間控制與路線／鬧鐘頁面排版。

## App Review Notes

**Never paste from the historical blocks below.** The only current note is the
version-specific one for `1.6.8`. The older blocks are kept as a record of what was told to
App Review at the time, and several are now false: the pre-`1.6.2` ones say alarm scheduling
uses local notifications only (untrue since `1.6.3` adopted AlarmKit — and it undercuts the
2.1(a) reply, which rests on AlarmKit requiring the widget extension) and that the app does
not track (untrue since `1.6.5` added ATT), while everything up to `1.6.6` describes Google
AdMob and `npa=1`, which `1.6.7` replaced with Unity LevelPlay.

### Version-specific note prepared for 1.6.9 (28) — CURRENT

Paste the 1.6.8 note below with the build number changed to `1.6.9 (28)`, and add this
paragraph at the end, because 2.5.18 is the guideline this release touches and a reviewer
should not have to hunt for the control:

```
Per guideline 2.5.18, users can report an inappropriate ad in two places: a "Report this ad" link directly under the banner, and a "Report an ad" row in the "Ads" card at the bottom of the Alarm tab (the same card holds the ad privacy options in GDPR regions). Both open a prefilled email to the developer that identifies the specific ad shown.

New in this version: an optional "Evening preview" local notification the night before a scheduled alarm (21:00 by default, adjustable), stating what the alarm will do. A "Send a preview" button under the toggle delivers a sample a few seconds later. On iOS 26 this is the first feature that requests notification permission (the alarm itself uses AlarmKit, which has its own permission), so after scheduling an alarm you will see a notification permission prompt as well. Declining it disables only the preview; the alarm still rings.
```

### Version-specific note prepared for 1.6.8 (27) — carried into 1.6.9

Update the build number if it moves.

Written around the one thing most likely to go wrong in review: a reviewer spends the three
free generations, then taps the exchange in a datacentre with tracking denied, where no
rewarded ad fills. `1.6.4` was rejected under 2.1 for a reviewer reaching a dead end, so the
note says in advance what that screen means and that nothing is broken.

```
AI VOICE ALARM (new in this version)

Alarm sound → "AI 人聲" / "AI Voice" opens a screen where the user types what the alarm
should say and picks one of six voices. Tapping Generate sends only those words, the chosen
voice, and the app's language to a relay service we operate, which passes them to Google
Cloud Text-to-Speech and returns audio. The finished sound is stored on the device and rings
offline. No account, no personal data, nothing linked to the user. This is declared in App
Privacy as Other User Content, used for App Functionality, not linked to identity and not
used for tracking, and it is described in the privacy policy under "AI Voice Alarm".

The six voice previews are audio files bundled in the app. They play offline and cost
nothing, so every voice can be heard before anything is generated.

FREE ALLOWANCE AND REWARDED VIDEO

The first three generations are free. After that the screen offers a rewarded video in
exchange for one more, which guideline 3.2.2(x) permits ("completing a level, watching an
ad"). No purchase is involved and no IAP is required to use any part of the app.

If no rewarded video is available — which is likely in a test environment, and is also what
happens when ad tracking is declined or ad consent is dismissed — the screen says so and
offers nothing further. This is the intended behaviour, not a failure:

  • Alarms already set continue to ring normally, including ones already using an AI voice.
  • Every other alarm sound, and the rest of the app, is unaffected.
  • The feature never requires enabling tracking or accepting ads to be used at all; the
    three free generations work regardless of both answers.

REPORTING ADS

Alarm tab → "Report an ad" opens a prefilled mail draft, per guideline 2.5.18.

TESTING THE ALARM

As in previous versions, alarms use AlarmKit on iOS 26 and later, which is why the app ships
the RainyClockAlarmWidget extension. Please test on an iPhone; on iPad the app runs in iPhone
compatibility mode.
```

### Version-specific note prepared for 1.6.7 — superseded by 1.6.8

```
This build changes how ads are served. They were previously served by Google AdMob; they are
now served by Unity LevelPlay (the ironSource mediation SDK). No user-facing feature changed,
and nothing outside the advertising code was touched.

App Tracking Transparency is unchanged. On first launch the ATT permission request appears on
the Route tab, which is the app's first screen, in every region. There is no login and nothing
to configure. If the prompt does not appear, please check that "Allow Apps to Request to Track"
is enabled in Settings > Privacy & Security > Tracking. Until tracking is allowed, the
advertising identifier is not used and ads are requested as non-personalized.

In the European Economic Area, the UK, and Switzerland, an ad-consent dialog is shown before
the advertising SDK starts. It is now the app's own dialog: Google's User Messaging Platform
was removed together with the Google advertising SDK. Users can revisit that choice at any
time from "Ad privacy options" on the Alarm tab.

The privacy policy at https://shukaihu.github.io/RainyClock/privacy-policy.html has been
updated to name Unity LevelPlay as the advertising provider.

Background modes: the app declares Background App Refresh and Background Processing. It uses
them for one purpose — re-checking the weather forecast shortly before a scheduled alarm, so
that each morning's alarm is moved earlier only if rain is actually forecast for that morning.
The app has no server and sends nothing anywhere; the background task calls Apple Weather /
WeatherKit and re-registers the local alarm.
```

If 2.1(a) (Home Screen widgets) is raised again, append the iPhone-only/AlarmKit paragraph
from the `1.6.5` block below verbatim; it is left out here because that rejection was
answered and cleared, and re-arguing a settled point invites a fresh look at it.

### Historical — the generic note used up to 1.6.2

Rainy Clock uses Apple Maps for route preview and Apple Weather / WeatherKit for home and office weather checks. Alarm scheduling uses local notifications only. The app includes a Google AdMob banner ad at the bottom of the screen. No login is required.

雨天鬧鐘使用 Apple Maps 顯示路線預覽，並使用 Apple Weather / WeatherKit 檢查住家與公司附近天氣。鬧鐘排程只使用本機通知。App 底部有 Google AdMob 橫幅廣告。不需要登入。

### Historical — version-specific note prepared for 1.6.2 (17)

The note carried over from the 5.1.2(i) resolution still described build `1.6 (10)` and said nothing about the new consent flow, so this replacement was prepared:

```
This app does not track users. The App Privacy information declares no data types as used
for tracking, and ads are served via Google AdMob configured for non-personalized ads only
(npa=1), with no AppTrackingTransparency prompt and no IDFA access.

New in this build (1.6.2 / 17): a Google UMP consent flow runs before the Mobile Ads SDK is
initialised for users in the EEA, the UK, and Switzerland; those users can revisit their
choice via "Ad privacy options" in Settings. The Apple Weather attribution mark and legal
link remain in the Route tab weather section, as reviewed in 1.6.1 (16).
```

The "Sign-in required" checkbox in App Review Information was also found checked with a demo account, even though the app has no login. It should be cleared.

### Historical — version-specific note prepared for 1.6.5

Superseded by the `1.6.7` note above; kept for the 2.1(a) paragraph, which is still the best
statement of that argument.

```
This build adds App Tracking Transparency.

Where the prompt appears: launch the app, the ad-consent dialog appears first, and the ATT
permission request follows immediately after it on the Route tab (the first screen). No other
step is required — there is no login and no configuration to enter. The prompt is requested in
every region, not only in the EEA. If it does not appear, please check that "Allow Apps to
Request to Track" is enabled in Settings > Privacy & Security > Tracking.

Ads are requested as non-personalized (npa=1) unless the user grants tracking permission, and
the App Privacy information has been updated to declare data used to track.

Background modes: the app declares Background App Refresh and Background Processing. It uses
them for one purpose — re-checking the weather forecast shortly before a scheduled alarm, so
that each morning's alarm is moved earlier only if rain is actually forecast for that morning.
The app has no server and sends nothing anywhere; the background task calls Apple Weather /
WeatherKit and re-registers the local alarm.

Regarding "unable to add Widgets at the Home Screen" (2.1(a)): Rainy Clock is an iPhone-only
app and does not provide a Home Screen widget. The widget extension it ships contains only the
alarm's Live Activity, which AlarmKit requires in order to show the snooze countdown on the
Lock Screen and in the Dynamic Island (iPhone, iOS 26 and later). On iPad the app runs in
iPhone compatibility mode, where iOS does not offer third-party widgets at all. We kindly ask
that this be reviewed on an iPhone running iOS 26.
```

### Historical — follow-up reply sent for build 23

The reply below named build 20, which ITMS-91064 invalidated before review saw it. This
follow-up is what points App Review at the build that actually exists, and covers the two
things that changed since: the corrected privacy policy and the new background modes.

```
Follow-up to our previous reply.

The build referenced there, 1.6.5 (20), was invalidated during upload processing
(ITMS-91064) before it reached review, so it no longer exists. The build now attached to
this version is 1.6.5 (23). It contains the same App Tracking Transparency implementation
described in our earlier message, plus two additions:

1. The privacy policy at https://shukaihu.github.io/RainyClock/privacy-policy.html has been
   updated. It previously stated that the app does not track users, which was written before
   App Tracking Transparency was added; it now describes the tracking permission request and
   what each answer means.

2. The app declares Background App Refresh and Background Processing. They are used for a
   single purpose: re-checking the weather forecast shortly before a scheduled alarm, so the
   alarm is moved earlier only on mornings when rain is actually forecast. The app has no
   server — the background task calls Apple Weather / WeatherKit and re-registers the local
   alarm on the device.

Our position on Guideline 2.1(a) is unchanged and is set out in the previous reply: the app is
iPhone-only and ships no Home Screen widget, and the widget extension exists solely because
AlarmKit requires one to render the alarm's snooze countdown as a Live Activity. We kindly ask
that this be reviewed on an iPhone running iOS 26 or later.

Thank you for your time.
```

### Historical — reply sent in App Store Connect for the 1.6.4 (19) rejection

```
Thank you for the review.

Guideline 5.1.2(i): resolved in build 1.6.5 (20), which implements App Tracking Transparency.
The permission request is presented on first launch, immediately after the ad-consent dialog,
on the app's first screen (the Route tab), in every region. Until permission is granted, ad
requests are sent as non-personalized. The app privacy information in App Store Connect has
been updated to disclose data used to track.

Guideline 2.1(a): we believe this is not a defect in the app. Rainy Clock is an iPhone-only
app (target device family: iPhone) and has never offered a Home Screen widget, in its
description, its screenshots, or its binary. The bundled widget extension contains only an
ActivityConfiguration: AlarmKit requires a widget extension in order to display the alarm's
snooze countdown as a Live Activity on the Lock Screen and in the Dynamic Island on iPhone
with iOS 26 or later. It provides nothing that can be added to the Home Screen. In addition,
the review was performed on an iPad Air 11-inch (M3), where the app runs in iPhone
compatibility mode; iPadOS does not offer third-party Home Screen widgets for apps running in
that mode. We kindly ask that this functionality be reviewed on an iPhone running iOS 26.
```

## Privacy Nutrition Label Draft

Final answers should be verified in App Store Connect before submission.

| Area | Draft Answer |
| --- | --- |
| Account creation | No |
| User-generated content | **Yes, once the AI voice alarm ships.** The user types the line their alarm speaks, and it is sent to a relay and on to Google to be synthesized. In the App Privacy questionnaire this is *Other User Content*, collected for App Functionality, **not** linked to identity and **not** used for tracking |
| Location data | Used for app functionality when resolving route/weather locations |
| Contact info | Not collected by the app |
| Backend server | One, `weather-proxy` on Cloud Run — signs WeatherKit requests for Android, and synthesizes AI voice for both. App Store Connect never asks this; the row is here because the store description and the privacy policy both used to claim there was none |
| Third-party SDKs | Unity LevelPlay (ironSource) SDK. **Changed in `1.6.7`** — the Google Mobile Ads SDK and Google User Messaging Platform were removed |
| Advertising | Unity LevelPlay banner ads (one banner, no Google demand behind it — the AdMob account is terminated) |
| Tracking | Yes, from `1.6.5 (20)`: ATT is implemented, so Device ID and advertising/usage data must be checked as "Used to Track You" |

**This table is a planning aid, not a mirror of the App Store Connect form.** The rows above
name SDKs and vendors because that is useful to us; App Store Connect never asks for them. Its
App Privacy questionnaire asks only which data types are collected, for what purpose, and
whether each is used for tracking — the question reads "you or your third-party partners", so
partners are in scope but are never named. Swapping Google for Unity therefore changes nothing
in that form. Where the vendor's name does have to be right is the privacy policy page and the
App Review note.

## Screenshots Still Needed

Prepare screenshots for the required device sizes in App Store Connect:

- Route tab with valid addresses, route preview, and route weather.
- Alarm tab with weekday selection, alarm time, rain lead-time slider, rain threshold, and sound picker.
- Optional: address validation state showing the actual address in use.
