# App Store Connect Metadata / App Store Connect 素材

## App Information

| Field | Value |
|-------|-------|
| App Name | Jack Weather Clock |
| Subtitle | Rain-aware alarm for commuters |
| Bundle ID | com.shukaihu.JackWeatherClock |
| SKU | jackweatherclock-1 |
| Primary Category | Utilities |
| Content Rating | 4+ |
| Privacy Policy URL | (host privacy-policy.html on GitHub Pages or Notion — see below) |

---

## Description (English — 4000 chars max)

```
Jack Weather Clock sets your morning alarm earlier when it's going to rain on your commute.

HOW IT WORKS
Enter your home and work address, pick your commute mode (car, scooter, walking, or transit), and set your normal alarm time. Then tell the app how early you want to wake up on rainy days, and a rain probability threshold.

When you tap "Schedule Smart Alarm," the app checks the weather forecast along every segment of your actual commute route using Apple Weather. If any segment looks rainy, it schedules your alarm early — automatically.

FEATURES
• Real route-based forecast — checks actual road segments, not just a single location
• Supports car, scooter, walking, and public transit routes
• Adjustable lead time: 1 to 120 minutes earlier
• Adjustable rain probability threshold: 10% to 90%
• Custom alarm sound
• English and Traditional Chinese interface
• Weather data provided by Apple Weather

PRIVACY
Your addresses stay on your device. The app has no backend server and no account required. Weather and routing queries go directly to Apple's services.

REQUIREMENTS
• iPhone with iOS 17.0 or later
• Internet connection for weather and route data
```

---

## Description (Traditional Chinese / 繁體中文)

```
Jack 雨天鬧鐘：通勤路線預報下雨時，自動把鬧鐘提前。

如何使用
輸入住家和公司地址，選擇通勤方式（開車、機車、步行或大眾運輸），設定平常鬧鐘時間，再告訴 App 雨天要提前幾分鐘，以及降雨機率門檻。

點下「設定智慧鬧鐘」後，App 會透過 Apple Weather 檢查你實際通勤路線上每個路段的天氣預報。只要任一路段看起來會下雨，就自動把鬧鐘提前排程。

功能特色
• 以實際路線為依據的預報，而非單一地點
• 支援開車、機車、步行和大眾運輸
• 可調整提前時間：1 到 120 分鐘
• 可調整降雨門檻：10% 到 90%
• 自訂鬧鐘音效
• 支援英文與繁體中文介面
• 天氣資料由 Apple Weather 提供

隱私保護
地址資料保留在你的裝置上。App 沒有後端伺服器，不需要建立帳號。天氣和路線查詢直接傳送至 Apple 的服務。

系統需求
• iPhone，iOS 17.0 或更新版本
• 需要網路連線以取得天氣和路線資料
```

---

## Keywords (English — 100 chars max)

```
weather,alarm,rain,commute,clock,smart alarm,weather alarm,rain alert,forecast,transit
```

## Keywords (Traditional Chinese — 100 chars max)

```
天氣,鬧鐘,下雨,通勤,雨天,智慧鬧鐘,氣象,雨量,路線,提醒
```

---

## What's New (Version 1.0)

```
Initial release. Jack Weather Clock checks the weather along your commute route and moves your alarm earlier on rainy days.
```

繁體中文：
```
初始版本。Jack 雨天鬧鐘會檢查通勤路線的天氣預報，在可能下雨時自動提前鬧鐘。
```

---

## Privacy Nutrition Label (App Store Connect answers)

Fill in **Data Not Collected** — the app itself sends no data to any developer server.

However, because the app passes your addresses to Apple's CLGeocoder and WeatherKit:
- Select: **Data Not Linked to You** → **Other User Contact Info** (the home/work address)
- Select: **Data Not Linked to You** → **Precise Location** (derived from address, only for weather lookup)
- Both under purpose: **App Functionality**

If in doubt, select **No** for all data types collected (since data goes to Apple's own APIs, not your servers).

---

## Screenshot States to Capture

### Screenshot 1 — Initial / Settings view
- App freshly opened, form empty or with sample addresses
- Shows: address fields, alarm time, rain threshold slider, schedule button

### Screenshot 2 — Rain detected, alarm adjusted
- Addresses containing "rain" typed (mock triggers rain scenario)
- Shows: "Scheduled Result" section + "Route Weather" with rain icons
- Status message: "Rain threshold exceeded. Alarm adjusted."

### Screenshot 3 — No rain, normal alarm
- Same but with addresses not containing "rain"
- Shows: route weather segments with clear/cloudy icons
- Status message: "Rain threshold not exceeded. Alarm scheduled."

---

## Privacy Policy Hosting Options

**Option A — GitHub Pages (free, professional)**
1. Push `docs/privacy-policy.html` to your GitHub repo
2. GitHub repo Settings → Pages → Source: Deploy from branch → /docs
3. URL will be: `https://<username>.github.io/<repo>/privacy-policy.html`

**Option B — Notion (fastest)**
1. Create a new Notion page
2. Copy content from privacy-policy.html into the page
3. Click Share → Publish to web
4. Copy the public URL
