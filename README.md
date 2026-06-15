# Rainy Clock / 雨天鬧鐘

## English

Rainy Clock is an iOS smart alarm concept that adjusts a commute alarm when rain is detected along the route between home and work.

### Goal

The user enters:

- Home address
- Work address
- Commute mode: car, scooter, or walking
- Normal alarm time
- Rain lead time, for example 30 minutes
- Rain probability threshold

The app evaluates the selected commute route. If the rain probability on any route segment meets or exceeds the user's threshold, it schedules the alarm earlier by the configured lead time.

### Current Status

- SwiftUI iOS app skeleton
- Address, commute mode, alarm time, rain lead-time, and rain threshold settings
- English and Traditional Chinese UI strings
- Persisted commute settings through `UserDefaults`
- Local notification scheduling
- Mock route weather service for end-to-end UI flow
- MapKit route service skeleton with geocoding and route lookup
- Weather sampling protocol and route polyline sampler
- WeatherKit-backed route weather sampling for Release builds

### Build

Open `RainyClock.xcodeproj` in Xcode, or run:

```sh
xcodebuild -project RainyClock.xcodeproj -scheme RainyClock -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

### Build Modes

- Debug uses `MockRouteWeatherService` so the app can be installed on a real iPhone with a free Apple Personal Team.
- Release uses `MapKitRouteWeatherService` and `WeatherKitSamplingService`, so it requires a paid Apple Developer Program team with WeatherKit enabled.

### Personal Team Device Testing

Debug builds let you test UI, settings persistence, notification permissions, custom alarm sound, and alarm scheduling without paid WeatherKit entitlements.

### WeatherKit Setup

Real route weather requires a paid Apple Developer Program team and the WeatherKit capability for the app's bundle identifier. After enabling WeatherKit in Xcode Signing & Capabilities, Release builds use the WeatherKit route weather service automatically.

### Next Technical Milestones

1. Enable a paid Apple Developer Program team for Release WeatherKit testing.
2. Run Release on a real iPhone and verify WeatherKit route sampling.
3. Add background refresh or server push strategy for checking weather at the configured lead-time point.
4. Add multiple commute profiles and weekday/weekend schedules.
5. Add route selection when MapKit returns multiple candidates.

### Open Product Questions

- Should weather refresh be handled locally with BGTaskScheduler, or reliably through a lightweight server and push notification?
- Should heavy rain add more time than light rain in a later version?
- Should scooter routing use MapKit automotive routes, or a Taiwan-specific routing provider with scooter restrictions?

---

## 繁體中文

雨天鬧鐘是一個 iOS 智慧鬧鐘概念 App：當住家到公司的通勤路線可能下雨時，自動把鬧鐘提前。

### 目標

使用者輸入：

- 住家地址
- 公司地址
- 通勤方式：開車、機車或步行
- 平常鬧鐘時間
- 雨天提前時間，例如 30 分鐘
- 降雨機率門檻

App 會評估所選通勤路線；只要任一路段的降雨機率達到或超過使用者設定的門檻，就依照設定的提前時間排程較早的鬧鐘。

### 目前狀態

- SwiftUI iOS App 骨架
- 支援地址、通勤方式、鬧鐘時間、雨天提前時間與降雨門檻設定
- UI 字串支援英文與繁體中文
- 透過 `UserDefaults` 保存通勤設定
- 本機通知排程
- 使用 mock 路線天氣服務完成端到端 UI 流程
- 已新增包含地址轉座標與路線查詢的 MapKit 路線服務骨架
- 已新增天氣取樣 protocol 與路線 polyline 取樣器
- Release builds 已接上 WeatherKit 真實路線天氣取樣

### 建置

使用 Xcode 開啟 `RainyClock.xcodeproj`，或執行：

```sh
xcodebuild -project RainyClock.xcodeproj -scheme RainyClock -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

### 建置模式

- Debug 使用 `MockRouteWeatherService`，因此可用免費 Apple Personal Team 安裝到真機。
- Release 使用 `MapKitRouteWeatherService` 與 `WeatherKitSamplingService`，因此需要付費 Apple Developer Program team 並啟用 WeatherKit。

### Personal Team 真機測試

Debug builds 可以先測 UI、設定保存、通知權限、自訂鬧鐘音效與鬧鐘排程，不需要付費 WeatherKit entitlement。

### WeatherKit 設定

真實路線天氣需要付費 Apple Developer Program team，並替 App 的 bundle identifier 啟用 WeatherKit capability。在 Xcode Signing & Capabilities 啟用 WeatherKit 後，Release builds 會自動使用 WeatherKit 路線天氣服務。

### 下一步技術里程碑

1. 啟用付費 Apple Developer Program team 以測試 Release WeatherKit。
2. 在真機跑 Release 並驗證 WeatherKit 路線取樣。
3. 加入背景更新或伺服器推播策略，在提前時間點檢查天氣。
4. 支援多組通勤設定與平日/週末排程。
5. 當 MapKit 回傳多條候選路線時，加入路線選擇。

### 尚待確認的產品問題

- 天氣更新應採用本機 BGTaskScheduler，還是以輕量伺服器搭配推播提高可靠性？
- 未來版本是否要讓大雨比小雨提前更多時間？
- 機車路線應先用 MapKit 汽車路線近似，還是改用符合台灣機車限制的路線服務？
