# Product Decisions / 產品決策

## English

### Initial Scope

The first version focuses on one commute profile: home to work. Users can choose a commute mode, set a normal alarm time, a rain lead time, and a rain probability threshold. If any route segment meets or exceeds that threshold, the app schedules the alarm earlier.

### Weather Strategy

The app is structured around a `RouteWeatherService` protocol. The default runtime implementation now uses `MapKitRouteWeatherService` for geocoding and route lookup, samples up to five representative route coordinates, and delegates each point to a WeatherKit-backed `WeatherSamplingService`. Mock services remain available for previews and tests.

The production implementation should:

1. Geocode home and work addresses.
2. Request routes for the selected commute mode.
3. Sample representative coordinates along the selected route.
4. Query WeatherKit for each sample around the commute window through `WeatherKitSamplingService`.
5. Return whether any segment meets or exceeds the chosen rain probability threshold.

WeatherKit requires the app bundle identifier to have the WeatherKit entitlement enabled in Apple Developer / Xcode Signing & Capabilities before real-device requests will succeed.

### Alarm Strategy

Local notifications are scheduled through `UNUserNotificationCenter`. If the adjusted alarm time has already passed today, the scheduler treats it as an immediate alarm instead of silently creating a stale calendar trigger.

The intended product behavior is to refresh weather at the configured lead-time point. For example, if the normal alarm is 7:30 and the rain lead time is 30 minutes, the app should check the selected route at 7:00. If the threshold is exceeded, the early alarm fires immediately; otherwise, the normal 7:30 alarm remains.

Because iOS does not guarantee exact background execution at a specific minute for third-party apps, production needs one of these strategies:

- Local-first: schedule a normal alarm and request a `BGAppRefreshTask` around the lead-time point, accepting that iOS may delay or skip the refresh.
- Server-backed: store the commute check server-side, evaluate weather at the lead-time point, and send a push notification if the early alarm should fire.

### Localization Strategy

All user-facing UI text should be backed by localized string resources. Documentation should include both English and Traditional Chinese in the same file so product and technical decisions stay aligned across languages.

### Design Questions

- Do users need separate weekday/weekend schedules?
- Should the app allow multiple workplaces or saved profiles?
- Should heavy rain add more time than light rain?
- Should the route be chosen automatically, or should users pick among route options?
- Should scooter mode use MapKit automotive routing as a first approximation, or a Taiwan-specific route provider?

---

## 繁體中文

### 初始範圍

第一版聚焦在單一通勤設定：住家到公司。使用者可以選擇通勤方式、設定平常鬧鐘時間、雨天提前時間與降雨機率門檻。只要任一路段達到或超過門檻，App 就會把鬧鐘提前。

### 天氣策略

App 以 `RouteWeatherService` protocol 作為路線天氣抽象層。預設執行時實作現在使用 `MapKitRouteWeatherService` 執行地址轉座標與路線查詢、沿路線取最多五個代表座標，並把每個座標交給 WeatherKit-backed `WeatherSamplingService`。mock services 仍保留給 preview 與測試使用。

正式版實作應該：

1. 將住家與公司地址轉成座標。
2. 依照使用者選擇的通勤方式查詢路線。
3. 沿著所選路線取樣代表性座標。
4. 透過 `WeatherKitSamplingService` 在通勤時間窗附近使用 WeatherKit 查詢各取樣點天氣。
5. 回傳是否有任何路段達到或超過使用者設定的降雨門檻。

WeatherKit 需要 App 的 bundle identifier 已在 Apple Developer / Xcode Signing & Capabilities 啟用 WeatherKit entitlement，真機請求才會成功。

### 鬧鐘策略

本機通知透過 `UNUserNotificationCenter` 排程。如果調整後的鬧鐘時間在今天已經過去，排程器會把它視為立即鬧鐘，而不是建立一個過期的 calendar trigger。

預期產品行為是在使用者設定的提前時間點刷新天氣。例如平常鬧鐘是 7:30、雨天提前時間是 30 分鐘，App 應在 7:00 檢查通勤路線。如果超過門檻，提早鬧鐘立即響起；否則保留 7:30 的正常鬧鐘。

由於 iOS 不保證第三方 App 能在指定分鐘精準背景執行，正式版需要選擇下列策略之一：

- 本機優先：先排程正常鬧鐘，並在提前時間點附近要求 `BGAppRefreshTask`，但接受 iOS 可能延遲或略過刷新。
- 伺服器支援：把通勤檢查存在伺服器端，在提前時間點評估天氣，需要提前時發送推播通知。

### 本地化策略

所有使用者可見的 UI 文字都應由本地化字串資源提供。文件應在同一份檔案內同時提供英文與繁體中文，確保產品與技術決策在兩種語言中保持一致。

### 設計問題

- 使用者是否需要平日/週末不同排程？
- App 是否要支援多個工作地點或已儲存通勤設定？
- 大雨是否應比小雨提前更多時間？
- 路線應自動選擇，還是讓使用者從多條路線中挑選？
- 機車模式應先用 MapKit 汽車路線近似，還是改用符合台灣機車限制的路線服務？
