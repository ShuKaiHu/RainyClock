# 臺灣鄉鎮市區地圖來源

`RainyClock/Resources/taiwan-townships.geojson` 是原生停班停課地圖的**顯示圖層**，由官方行政區界線簡化而成。它不參與鬧鐘是否略過、地址屬於哪個行政區或村里範圍的判斷，也不是測量、地籍或法律界線依據。

## 原始資料與授權

- 提供機關：內政部國土測繪中心。
- 官方目錄：[鄉鎮市區界線（TWD97 經緯度），政府資料開放平臺資料集 7441](https://data.gov.tw/dataset/7441)。
- 實際下載：該目錄直接連結的 [TGOS 鄉（鎮、市、區）界線 1140318 ZIP](https://www.tgos.tw/tgos/VirtualDir/Product/3fe61d4a-ca23-4f45-8aca-4a536f40f290/%E9%84%89%28%E9%8E%AE%E3%80%81%E5%B8%82%E3%80%81%E5%8D%80%29%E7%95%8C%E7%B7%9A1140318.zip)。
- 取得日期：2026-09-15；實際圖資檔名／版本：`TOWN_MOI_1140318`，即 **2025-03-18** 版本。取得日期不代表重新測繪日期，不宣稱涵蓋全部後續行政區界調整。
- 原始 ZIP：12,801,023 bytes；SHA256：`c5dc6c0f9a8cc1aad6758a0a6fb81b203718b37f42c5aa8e684262ca24a7d9dd`。
- 官方 DBF 欄位：`TOWNCODE`、`COUNTYCODE`、`COUNTYNAME`、`TOWNNAME`。`TOWNCODE` 保留八位字串及前導零；不是 NCDR CAP 的七位 `Taiwan_Geocode_103`。App 以縣市／鄉鎮名稱關聯此顯示圖層，不將兩套代碼直接等同。
- 原始 PRJ：`GCS_TWD97[2020]`，GRS80 橢球、經緯度；經 Mapshaper 轉成 WGS84 經緯度供地圖顯示，不主張測量等級的坐標精度。
- 授權：[政府資料開放授權條款－第 1 版](https://data.gov.tw/license)，可用於商業服務及改作，需保留顯名資訊。此圖資未使用政府標誌，也不表示政府為 App 背書。

顯名資訊（同時保存在 GeoJSON 的 `source.attribution`）：

> 內政部國土測繪中心 2025 鄉鎮市區界線（1140318）。此開放資料依政府資料開放授權條款第1版進行公眾釋出；本圖經簡化，僅供資訊顯示，非法律或測量界線依據。

App 的地圖資訊處應保留提供機關、圖資年份與授權連結。

檢索時也核對了 [NLSC 圖資服務雲下載頁](https://maps.nlsc.gov.tw/pro/download.jsp)：該頁雖標示下載項目更新於 2025-11-18，其鄉鎮 ZIP 內實際仍為 `TOWN_MOI_1120317`。因此本次使用官方目錄所連結、版本較新的 TGOS ZIP，沒有把下載頁更新日期誤當圖資日期。NLSC 另有 [2025 年 4 月界線釐整公告](https://www.nlsc.gov.tw/NLSC_Content.aspx?n=1742&s=327258&sms=9680)；上線時如需要最新細部界線，應重新確認官方供應版本並更新此來源鎖定，不把現在的顯示圖層描述為即時行政界線。

## 格式與涵蓋範圍

GeoJSON 為標準 `FeatureCollection`，主 `features` 一個鄉鎮市區一筆，`geometry.type` 統一為 `MultiPolygon`：

```text
features[].id = 八位 TOWNCODE 字串
features[].properties = { county, district, townCode, countyCode }
features[].geometry.coordinates[polygon][ring][point] = [longitude, latitude]
```

每個 polygon 第一個 ring 是外環，其餘是孔洞；畫圖需保留孔洞。`source` 保存來源、版本、取得日期、原檔雜湊與授權；這是 GeoJSON 允許的額外資訊。

主圖層的 **368 筆、22 縣市**與既有 `taiwan-districts.json` 的 368 組縣市／鄉鎮名稱完全一致，沒有缺漏或額外的鄉鎮。包括金門烏坵、連江四鄉、澎湖各鄉市、綠島、蘭嶼、琉球，以及原始檔提供的其他離島幾何。高雄市旗津區含原圖的遠海部分；主臺灣畫面應使用明確視窗，不能以全檔最小外框自動縮放而把臺灣縮得很小。

原 ZIP 另提供 `Town_Majia_Sanhe`：瑪家鄉含三和飛村的補充圖形，與主圖及鄰鄉部分重疊。它保留在 **`supplementalFeatures`**，格式相同，沒有混進主圖 368 筆、重切鄰鄉或自行推論其管轄關係。一般著色地圖先使用 `features`；若未來呈現補充層，應獨立標明，不能假設這是沒有重疊的行政分區。屏東縣政府的[瑪家鄉防災地圖](https://pteoc.pthg.gov.tw/PreventionUploads/PreventMap/2022/%E7%91%AA%E5%AE%B6%E9%84%89/7.%E7%91%AA%E5%AE%B6%E9%84%89%E9%98%B2%E7%81%BD%E5%9C%B0%E5%9C%96.pdf)也說明三和村住地與周邊鄉界的特殊情況。

## 重製流程

需求：Python 3、curl、Node.js、npm。版本固定 `mapshaper@0.7.61`，僅作圖資轉換工具，不加入 App 或伺服器的執行依賴。原始 ZIP 不放進 App。

```sh
python3 scripts/build_taiwan_townships.py
```

若已保存上述官方 ZIP，可離線重用該原檔（Mapshaper 仍須先存在 npm 快取）：

```sh
python3 scripts/build_taiwan_townships.py --archive /path/to/official.zip
```

腳本先核對原始 SHA256，僅解開預期的 SHP／DBF／SHX／PRJ／CPG 檔案；下載內容變更時會停止，避免無聲採用未審核版本。之後執行：

1. 建立整個主圖層的共用邊界拓撲，轉成 WGS84 顯示坐標。
2. 先展開每個 polygon，再以球面 Ramer–Douglas–Peucker、50 公尺門檻、`keep-shapes` 簡化，保護每個離島部分；Mapshaper 同時修復簡化引入的交叉。
3. 依原 `TOWNCODE` 合併，保留名稱與代碼；共用邊界只簡化一次。相接的同鄉多個部分可能合併，不是刪除島嶼。
4. 輸出到小數六位經緯度，使用 `fix-geometry` 修復取位引入的交叉。保留 GeoJSON 多邊形與孔洞，不使用自製方塊、圓點或猜測輪廓。
5. 檢查 368 筆／22 縣市、名稱一一對應、代碼唯一且前導零保留、座標有效、rings 封閉、離島存在、共用邊界和大小上限。

Mapshaper 官方方法與選項見[指令文件](https://mapshaper.org/docs/reference.html)及[拓撲說明](https://mapshaper.org/docs/guides/topology.html)。

## 本次驗證結果

- 主圖：368 個鄉鎮市區、22 縣市、1,029 個 polygon parts、52,032 個 coordinate positions。
- 簡化步驟沒有 collapsed rings；記錄的最大位移約 49.998 公尺。此數值是轉換工具的簡化統計，不是實地測量誤差保證。
- 展開到 GeoJSON 後仍有 21,604 條座標完全一致的共用 edges、960 組相鄰鄉鎮。另檢查臺北中正／萬華、臺中北區／西區、新北板橋／中和的共享邊界。
- 烏坵保留 2 個 polygon parts；南竿 45、北竿 47、莒光 60、東引 31。沒有為了主畫面裁掉遠海資料。
- 檔案含來源及補充層共 **1,263,037 bytes**（約 1.20 MiB），低於 1,500,000 bytes 預算。
- 輸出 SHA256：`223998519791eb5d2538b623e6e2637f9d242e1a048d00c7e0372c0cef6c44e2`。
- 以同一官方 ZIP 再執行一次完整轉換，第二份输出與 App 資源逐 byte 相同。

這些是圖資結構與轉換驗證；停班停課公告解析及鬧鐘邏輯仍由原有獨立服務負責。

## 2026-09-16 善化／安定核對與描邊修正

針對使用者畫面中的臺南市善化區及安定區，重新核對上列官方 ZIP 的 SHA256 及 SHP／DBF／SHX／PRJ 原始內容，再對照 App GeoJSON。兩區代碼分別為 `67000190`、`67000210`；原檔及輸出皆為一個有效 polygon、零孔洞，鄰接行政區相同。兩區沒有面積重疊，共用邊界仍存在；頂點方向由 SHP 順時針轉為 GeoJSON 逆時針，不代表鏡射。

| 指標 | 善化區 | 安定區 |
| --- | ---: | ---: |
| 原始／簡化後座標數 | 1,491／85 | 1,023／68 |
| 原始／簡化後面積 km² | 53.4524／53.3439 | 31.8643／31.8407 |
| 面積差 | −0.2030% | −0.0739% |
| 邊界 Hausdorff 距離 | 49.62 m | 49.13 m |
| 形狀交集／聯集 | 99.2442% | 98.8266% |

以上距離與面積只比較這份官方原檔及其顯示簡化版本，不代表地籍精度或最新實地界線。[官方原檔／App 疊圖](map-validation/tainan-official-comparison-2026-09-16.png)、[完整量測 JSON](map-validation/tainan-official-measurements-2026-09-16.json)。另核對 [NLSC 2025 年 4 月異動公告](https://www.nlsc.gov.tw/NLSC_Content.aspx?n=1742&s=327258&sms=9680)，臺南列出的嘉北里、嘉南里異動為里界，該公告沒有列出這兩區區界的變動。此檢查不等於所有後續版本均已核對。

SwiftUI 繪圖採 `x = longitude × cos(23.6°)`、`y = −latitude`，所有座標再使用同一縮放比例；縣市畫面沒有分別拉伸寬高。臺南在 360×265 與 265×360 pt 視窗皆維持原投影長寬比，善化位於安定東北，沒有軸交換、鏡射或旋轉。這是地方等距圓柱投影，並非測量用投影。

實際問題在高亮描邊：SwiftUI 預設 `StrokeStyle` 使用 miter 尖角連接。以原生 `Path.strokedPath` 測量同一份臺南路徑，4 pt 高亮線在 360×265 pt 畫面可伸到距原界線 **5.04 pt（善化）／5.57 pt（安定）**，使細碎凹角看似多出尖刺。改為 round 連接後，同一量測均限制在 **2.00 pt**，即線寬的一半。沒有因此改寫行政區頂點或重新畫界線。

已用原生 SwiftUI `ImageRenderer` 檢視[修正前](map-validation/tainan-stroke-before.png)及[修正後](map-validation/tainan-stroke-after.png)，並在行政區內加入住家／公司符號以區分地點高亮與白色選取外框。圖像使用真實 bundled 幾何及驗證用中性灰色填色，不是即時公告截圖。

新增回歸驗證涵蓋兩區名稱／代碼與鎖定界框、共用邊界、37 區完整臺南縣市視窗、直橫視窗等比投影、圖示點位落在區內，以及尖角不得超出半線寬。獨立原生幾何執行檢查與 ImageRenderer 產圖已通過；完整 iOS XCTest 由主流程統一執行，未在此平行啟動 Xcode suite。
