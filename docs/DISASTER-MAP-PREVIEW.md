# 台灣停班停課地圖：1.7.0 整合

2026-09-15，使用者已授權將原獨立預覽整合回 `RainyClock-iOS/` 的 **1.7.0 (29)**，供模擬器檢視。先前的 `RainyClock-dayoff-preview/` 仍保留；本文件現在描述原專案內的整合功能，並不代表已發布或正式公告服務已啟用。延續黑色背景、深灰圓角卡片、藍色操作按鈕；地圖的行政區顏色用來表示公告狀態。

## 入口與操作

- 本次頁面結構為「鬧鐘／設定」，設定包含「時間／路線／日曆／其他」。地圖放在「設定 → 日曆 → 停班停課地圖」；天災選項同屬日曆，鬧鐘狀態連往對應設定。
- 切換「今天／明天」，查看該日期的公告。
- 全台畫面含縣市外框、鄉鎮市區細線與澎湖、金門、馬祖、烏坵小圖。點選地區會放大其縣市；再次點選鄉鎮，或使用列表，查看公告原文。
- 點選住家／目的地卡片只在地圖定位，不變更保存的行政區，也不調整鬧鐘。經過的地區不會標成通勤判斷地點。
- 地圖下方提供行政區列表及 NLSC 圖資來源連結；公告詳細頁保留官方公告連結。正式介面沒有右上角三點選單或示範入口。

## 顏色與資料

| 顏色 | 意義 |
| --- | --- |
| 綠 | 官方明確公告照常上班、照常上課 |
| 紅 | 全天停班、停課 |
| 黃 | 僅停課 |
| 紫 | 僅停班 |
| 橘 | 部分時段或部分地區，須查看原文 |
| 灰 | 尚未確認、沒有公告、來源失效、撤銷、冲突或資料過期 |

沒有收到公告不會預設成正常；未知文字也不會自行解讀為放假。地圖使用獨立、唯讀的公告呈現邏輯，與實際鬧鐘是否成功略過分開。檢查時間超過 15 分鐘會轉為未確認；今天的全天公告仍可在下午查看，不受鬧鐘只判斷未來響鈴的條件影響。

正式服務尚未部署／設定時，正常入口保持未確認狀態。合成公告僅供 Debug 專用預覽，畫面頂端明確標示「示範資料，非即時公告」，不寫入真實公告快取或鬧鐘設定。今天／明天分段控制旁不顯示 Demo。

## 圖資

內政部國土測繪中心提供、TGOS 發布的 2025-03-18 版行政界線，涵蓋 22 縣市、368 鄉鎮市區，採保留共用邊界的 50 公尺簡化，檔案約 1.26 MB。圖資隨 App 保存，可離線查看，不需要位置權限或地圖伺服器。

主畫面以台灣本島及離島分圖顯示；南海遠端圖形保留在資源內，不拉伸本島的畫面。三和補充圖層保留於原資源，沒有混入主地圖造成重疊色塊。此圖供公告瀏覽，不是即時或法律界線，不用來判定住家與公司所在行政區。

完整來源、授權與重製步驟見 [TAIWAN-TOWNSHIP-BOUNDARIES.md](TAIWAN-TOWNSHIP-BOUNDARIES.md)。

## 開發預覽

Debug 啟動參數 `-disaster-map-preview` 會直接打開獨立的地圖示範。可加 `-disaster-map-county 新北市` 查看縣市畫面。此入口使用獨立設定儲存區，略過通知註冊與廣告；Release 不包含此入口。

2026-09-16 核對使用者指出的臺南善化／安定形狀：官方輪廓及投影沒有標錯、鏡射或非等比拉伸；修正了高亮線條尖角外伸，並以房屋／大樓符號區分住家與目的地。官方疊圖、量測和繪圖回歸結果見 [圖資核對紀錄](TAIWAN-TOWNSHIP-BOUNDARIES.md#2026-09-16-善化安定核對與描邊修正)。

## 驗證

以下是移入原專案之前的獨立預覽紀錄，**不是這次 1.7.0 合入後的新結果**。原生頁面結構也在此次移植，需按 [模擬器檢查表](1.7.0-SIMULATOR-CHECKLIST.md)重新檢查導覽、示範與資料不可用狀態。

- iOS 模擬器 XCTest：163 通過、6 項既有 Keychain 測試因未簽署環境略過、0 失敗。新增 10 項公告顏色判斷及 3 項完整圖資／幾何驗證。
- 後續只調整版面高度、圖資署名位置及地點標題，Debug build 再次成功；繁中、英文地圖字串完整。
- 已檢視原生模擬器全台畫面；Mac 鎖定使互動操作工具不可用，尚未實際點選驗證。正式服務與真機背景流程依舊未啟用。
- 完整測試結果：`/tmp/RainyClock-DayOff-DerivedData/Logs/Test/Test-RainyClock-2026.09.15_21-43-02-+0800.xcresult`。

English: With the owner's approval, the native township map is now integrated into the original iOS 1.7.0 (29) workspace under Settings → Calendar. It remains a read-only announcement view with today/tomorrow controls, county navigation, island insets, saved-place highlights, original announcement details and an accessible region list. Unknown or unavailable data is never colored normal. Synthetic examples are labeled and are not live announcements. The previous separate-preview test record does not validate this new integration; deployment and physical-device checks remain pending.
