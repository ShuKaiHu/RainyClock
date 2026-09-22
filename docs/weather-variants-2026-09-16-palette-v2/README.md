# 天氣 9 種組合

9 張原尺寸 PNG 均來自 iPhone 17 Pro / iOS 26.5 Simulator 的原生 Save Screen。
使用更新配色後的 CommuteWeatherCard 與明確標示的示範資料。截圖沒有重繪或調色。

檔名左側為 Home、右側為 Work：clear 晴天、rain 雨天、cloudy 陰天。
weather-9-grid.png 為原截圖天氣卡區域的九宮格整理；個別 PNG 是未裁切的完整截圖。
index.html 可在本機瀏覽器開啟比較，點圖查看完整原圖。

重現：Debug Simulator 啟動參數 -weather-scene-preview -weather-home clear -weather-work rain。
將兩端參數分別改為 clear / rain / cloudy 可重現全部九種。
示範資料不寫入正式路線、預報快取或鬧鐘排程。
