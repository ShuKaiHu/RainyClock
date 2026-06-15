# App Store Connect Metadata / App Store Connect 素材

## App Information

| Field | Value |
|-------|-------|
| App Name | Rainy Clock |
| Subtitle | Rain-aware alarm for commuters |
| Bundle ID | com.shukaihu.RainyClock |
| SKU | rainyclock-1 |
| Primary Category | Utilities |
| Content Rating | Expected 4+ |
| Privacy Policy URL | `https://shukaihu.github.io/RainyClock/privacy-policy.html` |
| Support URL | `https://shukaihu.github.io/RainyClock/support.html` |
| Marketing URL | Optional: `https://shukaihu.github.io/RainyClock/` |
| Copyright | TODO: `2026 Shu-Kai Hu` or legal entity name |
| Price | TODO: Free or paid tier |

---

## Promotional Text

English:
```
Wake up earlier only when rain is expected along your commute route.
```

繁體中文：
```
通勤路線可能下雨時，自動把鬧鐘提前。
```

---

## Description (English — 4000 chars max)

```
Rainy Clock sets your morning alarm earlier when it's going to rain on your commute.

HOW IT WORKS
Enter your home and work address, pick your commute mode (car, scooter, or walking), and set your normal alarm time. Then tell the app how early you want to wake up on rainy days, and a rain probability threshold.

When you tap "Schedule Smart Alarm," the app checks the weather forecast along your commute route using Apple Weather. If any route segment looks rainy, it schedules your alarm early.

FEATURES
• Route-based forecast — checks the commute path, not just a single city
• Supports car, scooter, and walking modes
• Adjustable lead time: 1 to 120 minutes earlier
• Adjustable rain probability threshold: 10% to 90%
• Weekday selection
• Custom alarm sounds with preview
• English and Traditional Chinese interface
• Weather data provided by Apple Weather

PRIVACY
Your settings are stored on your device. The app has no account system, no advertising SDK, and no analytics SDK. Weather and routing queries are handled through Apple's services.

REQUIREMENTS
• iPhone with iOS 17.0 or later
• Internet connection for route and weather data
• Notifications enabled for alarm alerts
```

---

## Description (Traditional Chinese / 繁體中文)

```
雨天鬧鐘：通勤路線預報下雨時，自動把鬧鐘提前。

如何使用
輸入住家和公司地址，選擇通勤方式（開車、機車或步行），設定平常鬧鐘時間，再告訴 App 雨天要提前幾分鐘，以及降雨機率門檻。

點下「排程智慧鬧鐘」後，App 會透過 Apple Weather 檢查你通勤路線上的天氣預報。只要任一路段看起來會下雨，就自動把鬧鐘提前排程。

功能特色
• 以通勤路線為依據的預報，而非只看單一城市
• 支援開車、機車和步行模式
• 可調整提前時間：1 到 120 分鐘
• 可調整降雨門檻：10% 到 90%
• 可選擇每週響鈴日
• 可選擇與試聽鬧鐘音效
• 支援英文與繁體中文介面
• 天氣資料由 Apple Weather 提供

隱私保護
你的設定會儲存在裝置上。App 沒有帳號系統、沒有廣告 SDK，也沒有分析 SDK。路線與天氣查詢會透過 Apple 的服務處理。

系統需求
• iPhone，iOS 17.0 或更新版本
• 需要網路連線以取得路線和天氣資料
• 需要開啟通知權限以收到鬧鐘提醒
```

---

## Keywords (English — 100 chars max)

```
weather,alarm,rain,commute,clock,smart alarm,weather alarm,rain alert,forecast
```

## Keywords (Traditional Chinese — 100 chars max)

```
天氣,鬧鐘,下雨,通勤,雨天,智慧鬧鐘,氣象,路線,提醒,預報
```

---

## What's New (Version 1.0)

English:
```
Initial release. Rainy Clock checks weather along your commute route and helps schedule an earlier alarm on rainy days.
```

繁體中文：
```
初始版本。雨天鬧鐘會檢查通勤路線的天氣預報，在可能下雨時協助排程提前鬧鐘。
```

---

## Review Notes

English:
```
Rainy Clock does not require an account. To test:
1. Allow notifications when prompted.
2. Enter a home address and work address.
3. Select car, scooter, or walking.
4. Adjust the alarm time, rain lead time, rain threshold, weekdays, and alarm sound.
5. Tap Schedule Smart Alarm.

The app uses Apple Maps for route preview and Apple Weather / WeatherKit for route weather in Release builds. Weather data attribution is shown in-app.
```

繁體中文：
```
雨天鬧鐘不需要帳號。測試方式：
1. 允許通知權限。
2. 輸入住家地址與公司地址。
3. 選擇開車、機車或步行。
4. 調整鬧鐘時間、雨天提前時間、降雨門檻、星期與鬧鐘音效。
5. 點選「排程智慧鬧鐘」。

Release builds 會使用 Apple Maps 預覽路線，並透過 Apple Weather / WeatherKit 查詢路線天氣。App 內已顯示天氣資料來源標示。
```

---

## Privacy Nutrition Label (Recommended App Store Connect answers)

Recommended conservative answer:

- Tracking: No
- Analytics: No
- Advertising: No
- Precise location/address use: App Functionality only
- Linked to user by developer: No

Suggested data types if App Store Connect asks:

- Location → Precise Location
  - Purpose: App Functionality
  - Linked to user: No
  - Used for tracking: No
- Contact Info → Physical Address / Other User Contact Info, only if the form treats typed home/work addresses as collected data
  - Purpose: App Functionality
  - Linked to user: No
  - Used for tracking: No

Rationale:

- The app has no developer backend, no account system, no analytics SDK, and no advertising SDK.
- Home/work address text is stored locally with `UserDefaults`.
- Address text and derived coordinates are used to request Apple Maps / WeatherKit functionality.

繁體中文建議：

- 追蹤：否
- 分析：否
- 廣告：否
- 精確位置 / 地址使用：僅用於 App 功能
- 是否由開發者連結到使用者：否

---

## Screenshot States to Capture

### Screenshot 1 — Route tab / 路線分頁
- Shows home/work address fields, route mode selector, route preview map, and route weather cards.

### Screenshot 2 — Alarm tab / 鬧鐘分頁
- Shows weekday selector, alarm time, rain lead time, rain threshold, alarm sound, and schedule button.

### Screenshot 3 — Scheduled result / 排程結果
- Shows a completed smart alarm schedule and route weather result.

Recommended: capture both English and Traditional Chinese screenshots if both localizations are submitted.

---

## Privacy Policy / Support Hosting Options

**Option A — GitHub Pages**
1. Push `docs/privacy-policy.html`, `docs/support.html`, and `docs/index.html` to GitHub.
2. GitHub repo Settings → Pages → Source: Deploy from branch → `/docs`.
3. Use these URLs in App Store Connect:
   - `https://shukaihu.github.io/RainyClock/privacy-policy.html`
   - `https://shukaihu.github.io/RainyClock/support.html`

**Option B — custom domain later**
1. Add `www.shukaihu.com` as the GitHub Pages custom domain.
2. Update App Store Connect URLs only after the custom domain is live.
