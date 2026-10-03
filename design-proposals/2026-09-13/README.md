# UI 與 Widget 提案狀態

此資料夾只放設計提案，未接入 App，也不代表已修改或核准發布 1.7.0。

## 使用者決策 — 2026-09-13

- 使用者對 `rainy-clock-concept.html` 的清爽 UI 方向反應正面；仍屬概念稿，沒有授權覆蓋原本 1.7.0。
- 使用者明確決定 **drop Finch 式養成概念**。停止規劃小雨雲養成、收集水滴、換裝與相關獎勵。
- `rainy-clock-tomorrow-cloud.html` 保留作為已否決的歷史提案，**不可視為下一步實作規格**。
- 明日準備卡屬實用資訊，不等於養成功能。使用者接著提出 Widget 方向，目前先確認可行性，尚未要求實作。

## Widget 初步評估

- 現有 `RainyClockAlarmWidget` 只註冊 `CommuteAlarmLiveActivity`，提供賴床倒數的鎖定畫面／動態島顯示；沒有一般 Home Screen 或 accessory timeline widgets。
- App 最低 iOS 17，現有 AlarmKit widget extension 最低 iOS 26。若一般 Widget 要支援 iOS 17–25，需另外處理 extension 部署版本與 AlarmKit availability；不能直接以現有 target 設定宣稱支援所有 App 使用者。
- 現有專案沒有 App Group。一般 Widget 需要可供 App 與 extension 共用的資料快照及同步機制，內容應反映成功註冊的排程，不把編輯中或失敗的設定顯示成已啟用。
- 建議先評估小尺寸「下一次鬧鐘」與中尺寸「鬧鐘＋明日準備卡」。點擊前往 App 的對應畫面；直接修改鬧鐘的互動可另外規劃。
- 沿用上午／下午或 24 小時制偏好；顯示假日不響、關閉、尚未排程、待更新等真實狀態。
- Widget 更新由 iOS 調度，應標示天氣更新時間，不能依靠 Widget 的刷新時間觸發實際鬧鐘。
- 回程天氣屬額外功能，目前原生 App 未提供；若放進中尺寸 Widget，需要新增資料取得與判斷。
- 產品目標可以是每天看得到與用得到；增加桌面使用不一定增加 App 開啟次數，不能保證回訪或廣告收入提升。

參考 Apple 官方文件：

- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)
- [Creating a widget extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)
- [Linking to specific app scenes](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)
- [Adding interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
