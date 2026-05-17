# Jack Weather Clock / Jack 雨天鬧鐘

## English

Jack Weather Clock is an iOS smart alarm concept that adjusts a commute alarm when rain is detected along the route between home and work.

### Goal

The user enters:

- Home address
- Work address
- Commute mode: car, scooter, walking, or public transit
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
- Service protocols prepared for WeatherKit integration

### Build

Open `JackWeatherClock.xcodeproj` in Xcode, or run:

```sh
xcodebuild -project JackWeatherClock.xcodeproj -scheme JackWeatherClock -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

### Next Technical Milestones

1. Replace `MockRouteWeatherService` with a MapKit route provider.
2. Replace `MockWeatherSamplingService` with WeatherKit-backed sampling.
3. Add background refresh or server push strategy for checking weather at the configured lead-time point.
4. Add unit tests for probability threshold and alarm-time adjustment edge cases.
5. Add multiple commute profiles and weekday/weekend schedules.

### Open Product Questions

- Should weather refresh be handled locally with BGTaskScheduler, or reliably through a lightweight server and push notification?
- Should heavy rain add more time than light rain in a later version?
- Should scooter routing use MapKit automotive routes, or a Taiwan-specific routing provider with scooter restrictions?

---

## 繁體中文

Jack 雨天鬧鐘是一個 iOS 智慧鬧鐘概念 App：當住家到公司的通勤路線可能下雨時，自動把鬧鐘提前。

### 目標

使用者輸入：

- 住家地址
- 公司地址
- 通勤方式：開車、機車、步行或大眾運輸
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
- 已預留 WeatherKit 整合用的 service protocol

### 建置

使用 Xcode 開啟 `JackWeatherClock.xcodeproj`，或執行：

```sh
xcodebuild -project JackWeatherClock.xcodeproj -scheme JackWeatherClock -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

### 下一步技術里程碑

1. 將預設服務從 `MockRouteWeatherService` 切換成 MapKit 路線提供者。
2. 將 `MockWeatherSamplingService` 換成 WeatherKit 天氣取樣實作。
3. 加入背景更新或伺服器推播策略，在提前時間點檢查天氣。
4. 補上降雨門檻與鬧鐘調整邊界情境的單元測試。
5. 支援多組通勤設定與平日/週末排程。

### 尚待確認的產品問題

- 天氣更新應採用本機 BGTaskScheduler，還是以輕量伺服器搭配推播提高可靠性？
- 未來版本是否要讓大雨比小雨提前更多時間？
- 機車路線應先用 MapKit 汽車路線近似，還是改用符合台灣機車限制的路線服務？
