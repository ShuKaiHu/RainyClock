# 天氣 9 種組合 · 雨天靛紫配色

本組比較只調整雨天配色；晴天與陰天維持 palette-v2。
9 張原尺寸 PNG 均為 iPhone 17 Pro / iOS 26.5 Simulator 的原生 Save Screen 截圖，使用明確標示的示範資料；沒有重繪或調色。

- 含雨天的 5 張由更新後的模擬器重新擷取：clear-rain、rain-clear、rain-rain、rain-cloudy、cloudy-rain。
- 不含雨天的 4 張直接沿用 ../weather-variants-2026-09-16-palette-v2/ 的原圖：clear-clear、clear-cloudy、cloudy-clear、cloudy-cloudy。檔案內容與 SHA-256 完全相同。
- manifest.json 記錄每張圖的尺寸、SHA-256、來源版本、擷取或沿用方式；沿用圖片另保留來源路徑與來源 SHA-256。

檔名左側為 Home、右側為 Work：clear 晴天、rain 雨天、cloudy 陰天。
weather-9-grid.png 為原截圖天氣卡區域的九宮格整理；個別 PNG 是未裁切的完整截圖。
index.html 可在本機瀏覽器開啟比較，點圖查看完整原圖。

重現：Debug Simulator 啟動參數 -weather-scene-preview -weather-home clear -weather-work rain。
將兩端參數分別改為 clear / rain / cloudy 可重現全部九種。
示範資料不寫入正式路線、預報快取或鬧鐘排程。
