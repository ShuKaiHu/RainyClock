# Product Decisions / 產品決策

## English

### Current Scope

Rainy Clock focuses on one commute profile: home to work. Users choose a commute mode, set a normal alarm time, select weekdays, set a rain lead time, and set a rain probability threshold. If weather around the next scheduled alarm check time meets the rain threshold, the app schedules an earlier local-notification alarm.

**The commute modes differ by platform, on purpose (2026-08-09).** iOS offers Car, Scooter, Walking and Transit; Android offers Car, Walking and Transit only. Google prices two-wheeler routing as an Enterprise-tier Routes API feature, outside the free Essentials allowance, while every other mode stays inside it. Scooters are the most common commute in this app's home market, so shipping the mode would have sent the majority of real traffic down the only billable path — on a free, ad-supported app currently earning US$0. Apple Maps has no two-wheeler mode and charges nothing, so iOS keeps the pill and quietly shows a driving estimate; there is no equivalent trick available on Android, where the honest choice is to not offer what we would be guessing at. Revisit if the app ever earns enough to absorb per-call routing costs.

### Weather Strategy

The app is structured around a `RouteWeatherService` protocol. The current release path uses `MapKitRouteWeatherService` with Apple Weather / WeatherKit.

The production implementation should:

1. Resolve home and work addresses.
2. Request a route for the selected commute mode.
3. Use the next selected weekday/time, minus the configured lead time, as the weather check time.
4. Query Apple Weather / WeatherKit for home-area and office-area weather around that check time.
5. Return whether either endpoint meets or exceeds the chosen rain probability threshold.

Open-Meteo is not part of the active release path.

**On-route sampling (queued for the next version, not in the shipped `1.6.5`):** the rain
check also covers interior points along the MapKit route — none under 4 km, the midpoint
from 4–20 km, quarter/mid/three-quarter points beyond — and *any* sampled point (home, en
route, office) over the threshold pulls the alarm earlier. Sampling is distance-based
because weather-model cells are a few km wide. Transit has no MKDirections geometry, and any
route failure silently degrades to the endpoint-only check: the alarm decision must never
depend on the routing infrastructure. The Android port ships the same rule
(`RouteSampler`), so both platforms decide identically.

### Address Strategy

Address entry should make resolution quality visible:

- If a user selects a dropdown suggestion, treat that result as confirmed.
- If the app resolves typed text without an explicit suggestion selection, show the actual address in use.
- If an address cannot be resolved, mark only that address field as invalid.
- The “Use this location” action should replace the typed address with the resolved address.

Google Places fallback can be added later, but should only run when Apple address resolution fails and after a production API key is configured.

### Alarm Strategy

Scheduling is split by system version behind the `NotificationScheduling` protocol, with `SystemAlarmScheduler` picking the path:

- **iOS 26+ — AlarmKit (`AlarmKitScheduler`).** As of `1.6.3`, the alarm overrides silent mode and Focus, presents the system full-screen alert, and offers a native snooze through `Alarm.CountdownDuration.postAlert`. Snooze can be switched off, and its interval is user-selectable from 1–15 minutes. The sound picker also gains a "System Default Alarm" entry, which maps to `AlertConfiguration.AlertSound.default` — the only Apple tone reachable from a third-party app, since the Clock app's tone list lives in the private ToneLibrary with no public API. It is offered on iOS 26+ only; the notification path has no equivalent. Because the alarm can enter the countdown state, AlarmKit requires a widget extension — `RainyClockAlarmWidget` renders the snooze Live Activity, and without it the system may drop alarms entirely. Needs `NSAlarmKitUsageDescription` and a one-time user authorization; no special Apple entitlement.
- **iOS 17–25 — local notifications (`LocalNotificationScheduler`).** Still silenced by the ring/silent switch, which no `UNUserNotificationCenter` API can bypass. It has no snooze button, so the snooze setting drives the follow-up ring interval instead — the same "how long until it rings again" number, without the tap — and turning snooze off means the alarm rings exactly once. Critical Alerts would pierce silent mode here, but Apple grants that entitlement only to medical/safety apps.

**Deliberate behaviour change in `1.6.3` (iOS 26 only):** the pre-26 path fires follow-up notifications at the snooze interval, up to 10 times, whether or not the user reacts. AlarmKit instead alerts once and snoozes only when the user taps the button, matching Apple's Clock app. Layering backup notifications on top would restore the "keeps nagging" behaviour but re-introduce the two-mechanism bookkeeping AlarmKit exists to remove, so the system behaviour was accepted — a full-screen alert that pierces silent mode is far harder to sleep through than a banner.

**Scheduled-alarm sync contract (since `1.6.3`):** the registered alarm always matches the visible settings. Parameter edits (weekdays, time, rain lead time, rain threshold, sound, snooze, commute mode) auto-refresh the alarm after a short debounce — no button press needed. Address edits instead *remove* the alarm outright: an alarm for a route the user has not confirmed should never ring, so the schedule button is the only way to re-arm it. The status line under the button is colour-coded — green (armed, in sync), orange (armed, syncing or stale), grey (nothing armed). The amber stale notice remains as a fallback for a failed auto-refresh.

The intended product behavior is to refresh weather at the configured lead-time point. For example, if the normal alarm is 7:30 and the rain lead time is 30 minutes, the app checks the selected route/weather at 7:00. If the threshold is exceeded, the early alarm fires; otherwise, the normal alarm remains.

### Day-off Suppression

Specified in full in `docs/DAYOFF-SPEC.md` (spec v1, 2026-09-10); nothing is implemented yet. The
product shape and the alternatives that were rejected, so they are not proposed again:

- **Announcements are read from NCDR's open-data feed, not scraped from `nds.html`.** The page the
  feature started from is server-rendered HTML with no date column and a `Disallow: /` robots.txt;
  the same DGPA announcements are published as keyless, open-licensed JSON at
  `alerts.ncdr.nat.gov.tw/JSONAtomFeed.ashx?AlertType=33`. A community GitHub mirror of the page was
  measured and rejected — at 06:00 Taiwan time its snapshots were a median 100 minutes stale.
- **Holidays come from the official 辦公日曆表 CSV, not from EventKit.** The system calendar's
  Taiwan holidays are not under our control and do not mark 補班日; the government CSV answers the
  question exactly, offline, in 6 KB, and needs no calendar permission or App Review purpose string.
- **Matching is per district, taking the union of home and destination.** County-level matching was
  rejected on real data: on 2025-11-10 New Taipei suspended seven mountain districts and left the
  rest of the city working, so a county rule would have silenced every alarm in the city. Districts
  merely passed through en route are deliberately not considered, even though the app has the route.
- **The user declares whether their morning is for 上班, 上課, or both**, because the announcements
  distinguish them (`照常上班、停止上課` is a real, published state).
- **The alarm rings and the ring screen explains, rather than the alarm being cancelled silently.**
  DGPA may announce as late as 04:30 and a backendless iOS app cannot reliably wake then, so the
  reliable design is one that can never make someone late. Announcements themselves are final —
  owner's ruling, 2026-09-10: a suspension is not revoked before the morning it applies to — so
  cancelling the alarm the night before is sound in principle. It still ships default-off until its
  state handling across reboot, termination and reinstall is defined.

### Localization Strategy

All user-facing UI text should be backed by localized string resources. Documentation should include both English and Traditional Chinese so product and technical decisions stay aligned across languages.

---

## 繁體中文

### 目前範圍

Rainy Clock 聚焦在單一通勤設定：住家到公司。使用者可以選擇通勤方式、設定平常鬧鐘時間、選擇星期、設定雨天提前時間與降雨機率門檻。若下一次鬧鐘判斷時間附近的天氣達到降雨門檻，App 就會提前安排本機通知鬧鐘。

**兩個平台的通勤方式刻意不同（2026-08-09 決定）。** iOS 提供開車、騎車、步行、大眾交通；Android 只提供開車、步行、大眾交通。Google 把兩輪路線（`TWO_WHEELER`）歸類為 Routes API 的 Enterprise 等級功能，不在 Essentials 的免費額度內，而其他三種模式都在額度內。機車是本產品主力市場最常見的通勤方式，保留這個選項等於讓**多數**真實流量走上唯一要付費的路徑——而這是一款目前收入為 US$0 的免費含廣告 App。Apple Maps 沒有兩輪模式且不收費，所以 iOS 保留這個選項、實際顯示的是開車的時間估計；Android 沒有這種取巧空間，誠實的做法就是不提供我們只能用猜的功能。若日後廣告收入足以吸收每次呼叫的路線費用，可以重新評估。

### 天氣策略

App 以 `RouteWeatherService` protocol 作為路線天氣抽象層。目前上架版本流程使用 `MapKitRouteWeatherService` 與 Apple Weather / WeatherKit。

正式版實作應該：

1. 解析住家與公司地址。
2. 依照使用者選擇的通勤方式查詢路線。
3. 使用下一個符合星期與時間設定的鬧鐘時間，扣掉雨天提前時間，作為天氣判斷時間。
4. 透過 Apple Weather / WeatherKit 查詢該時間附近的住家與公司附近天氣。
5. 回傳任一端點是否達到或超過使用者設定的降雨門檻。

Open-Meteo 已不在目前上架版本的主要流程中。

**路線途中取樣（排入下一版，未包含在已送審的 `1.6.5`）：** 降雨判斷同時涵蓋 MapKit 路線
上的內部取樣點——4 公里以下不取、4–20 公里取中點、更長取 1/4、1/2、3/4 三點——住家、
途中任一點、公司**任一處**超過門檻就提前響鈴。以距離為基準是因為天氣模型的網格本來就有
數公里寬。大眾運輸拿不到 MKDirections 路線幾何；任何路線查詢失敗都靜默退回只查兩端點，
鬧鐘判斷絕不依賴路線基礎設施。Android 版用同一套規則（`RouteSampler`），兩平台判斷一致。

### 地址策略

地址輸入應清楚顯示解析品質：

- 如果使用者從下拉式建議選單選取，視為已確認地址。
- 如果 App 直接用輸入文字解析出地址，但使用者沒有明確選取建議，顯示實際使用地址。
- 如果某個地址無法解析，只將該地址欄位標示為無效。
- 「使用此位置」按鈕應將輸入文字替換為實際解析出的地址。

Google Places fallback 可在未來加入，但只應在 Apple 地址解析失敗時啟用，且必須先設定正式 API key。

### 鬧鐘策略

排程依系統版本分成兩條路徑，都藏在 `NotificationScheduling` protocol 後面，由 `SystemAlarmScheduler` 選擇：

- **iOS 26 以上 — AlarmKit（`AlarmKitScheduler`）。** 自 `1.6.3` 起，鬧鐘會穿透靜音與專注模式，顯示系統全螢幕警示，並透過 `Alarm.CountdownDuration.postAlert` 提供原生賴床；賴床可關閉，間隔可在 1–15 分鐘之間選擇。鬧鈴清單也多了「系統預設鬧鈴」，對應 `AlertConfiguration.AlertSound.default` —— 這是第三方 App 唯一拿得到的 Apple 音色，時鐘 App 那整份鈴聲清單住在私有的 ToneLibrary，沒有公開 API。此選項僅在 iOS 26 以上出現，通知路徑沒有對等物。因為鬧鐘會進入 countdown 狀態，AlarmKit 要求必須有 widget extension —— `RainyClockAlarmWidget` 負責畫賴床 Live Activity，沒有它系統可能直接放棄鬧鐘。需要 `NSAlarmKitUsageDescription` 與一次性使用者授權，不需要向 Apple 申請特殊 entitlement。
- **iOS 17–25 — 本機通知（`LocalNotificationScheduler`）。** 靜音下仍然不會有聲音；`UNUserNotificationCenter` 沒有任何 API 能繞過靜音開關。這條路徑沒有賴床按鈕，所以賴床設定改為控制補發響鈴的間隔 —— 同樣是「隔多久再響一次」，只是不需要使用者按；關閉賴床就代表鬧鐘只響一次。Critical Alerts 能穿透靜音，但 Apple 只發給醫療／安全類 App。

**`1.6.3` 刻意的行為改變（僅 iOS 26）：** 舊路徑不管使用者有沒有反應，都會依賴床間隔補發、最多 10 次。AlarmKit 改成響一次，只有使用者按賴床才會再響，與 Apple 時鐘 App 一致。若在上面再疊備援通知，可以保留「不理也會再吵」的行為，但會把 AlarmKit 本來就要消除的雙機制同步複雜度搬回來，所以選擇接受系統行為 —— 穿透靜音的全螢幕警示本來就比橫幅通知難忽略得多。

**排程鬧鐘同步約定（自 `1.6.3` 起）：** 已註冊的鬧鐘永遠與畫面上的設定一致。參數調整（星期、時間、雨天提前時間、降雨門檻、鬧鈴、賴床、通勤方式）會在短暫 debounce 後自動重新排程，不需要按按鈕。地址調整則直接**移除**鬧鐘：使用者尚未確認的路線不該有鬧鐘替它響，所以只有排程按鈕能重新啟用。按鈕下方的狀態列以顏色區分 —— 綠色（已設定且同步）、橘色（已設定但同步中或不一致）、灰色（沒有鬧鐘）。琥珀色的「設定已變更」提示保留作為自動更新失敗時的後備。

預期產品行為是在使用者設定的提前時間點刷新天氣。例如平常鬧鐘是 7:30、雨天提前時間是 30 分鐘，App 應在 7:00 檢查路線與天氣。如果超過門檻，提早鬧鐘響起；否則保留正常鬧鐘。

### 停班停課與假日靜音

完整規格在 `docs/DAYOFF-SPEC.md`（spec v1，2026-09-10），目前尚未實作。產品形狀與**已被否決的替代方案**，記在這裡以免日後重複提案：

- **公告改讀 NCDR 的開放資料 feed，不爬 `nds.html`。** 這個功能的起點頁面是伺服器端渲染的 HTML、沒有日期欄位，`robots.txt` 是 `Disallow: /`；同一批人事行政總處公告以免金鑰、開放授權的 JSON 發布在 `alerts.ncdr.nat.gov.tw/JSONAtomFeed.ashx?AlertType=33`。GitHub 上有人鏡像那個頁面，實測後否決 —— 台灣時間 06:00 的快照中位落後 100 分鐘。
- **假日改讀官方辦公日曆表 CSV，不用 EventKit。** 系統行事曆的台灣假日內容不受我們控制，也不標補班日；政府 CSV 只有 6 KB、可離線、答案精確，而且不需要行事曆權限與 App Review 用途說明。
- **比對粒度是「區」，並取住家與目的地的聯集。** 縣市級比對已被真實資料否決：2025-11-10 新北市只停了七個山區的區，其餘照常上班，用縣市規則會把全市的鬧鐘都關掉。通勤途中經過的區刻意不列入判斷，即使 App 手上就有路線。
- **由使用者自己宣告早上是為了上班、上課、還是兩者。** 因為公告本身就會區分（`照常上班、停止上課` 是真實存在的狀態）。
- **鬧鐘照響、由響鈴畫面說明，而不是安靜地把鬧鐘關掉。** 人事行政總處最晚可能 04:30 才公告，而沒有後端的 iOS App 無法保證在那個時間醒來，所以唯一可靠的設計是「永遠不會害人遲到」的那一種。公告本身則是確定的 —— 2026-09-10 由 owner 裁定：停班公告不會在生效的那個早上之前被撤回 —— 所以「前一晚直接取消鬧鐘」原理上成立，但在重開機、App 被終止、重新安裝之後的狀態處理定義清楚之前，仍然預設關閉。

### 本地化策略

所有使用者可見的 UI 文字都應由本地化字串資源提供。文件應同時提供英文與繁體中文，確保產品與技術決策在兩種語言中保持一致。
