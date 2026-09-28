# 會員雲端測試環境

2026-09-16：使用者授權建立 Google Cloud 測試環境。這份文件記錄實際部署，
不代表已開通正式會員付款，也不取代 Apple Sandbox／App Attest 的真機驗收。

## 新接線與 build 30 上傳 — 2026-09-21 19:43

正式／TestFlight 服務與獨立資料庫已建立，Release URL 已設定，1.7.0（30）已由 Apple
完成處理並加入內部測試群組。具體資源、測試、尚未通過事項集中於
[正式接線與上傳驗收](1.7.0-RELEASE-READINESS.md)。下方 19:22 的盤點及原 Debug Sandbox
資源保留為歷史；不能再據此判定 Release URL 空白。公開收費尚未送審或發布。

## 最新：台灣月訂閱成功，正式環境仍待完成 — 2026-09-21 19:22

- 使用者真機確認 NT$10 月訂閱成功、Subscriber、有效至 19:26、Auto-renewal On，
  買斷價 NT$100。讀回已驗證 Sandbox monthly 交易：status=1、autoRenewStatus=1、
  revocationDate=null，session／purchases／通知200。此前美國買斷亦已成功。
- 最新雲端讀回仍僅會員 Sandbox＋既有 weather：目前會員服務 App Attest=development、
  TTS_DISABLED=1、未設 LevelPlay callback private key；不是可直接上架的收費環境。
- TestFlight／App Review 必須使用 production App Attest；正式版還需要已驗證交易
  的 Sandbox／Production 安全分流與資料隔離。不能只把 Release URL 指向目前 Debug 測試入口。
- Release URL 仍空白，本地最新 archive 是 9/16 的 1.7.0（29），不含本次最新變更。
  尚未重新封存、上傳或送審；不把月訂閱 UI 通過當作整體正式上線完成。

## 真機買斷與會員頁調整 — 2026-09-21 晚間

- iPhone 16 Pro 已由 Xcode 的 `RainyClock Membership Sandbox` scheme 啟動，
  Run 的 StoreKit Configuration 為 None。使用者 18:55 截圖確認買斷會員、Purchased、
  每日一次及月訂閱由買斷涵蓋；Cloud Run session／purchases／通知有 200，Firestore
  保存已驗證的 Sandbox lifetime 交易。這是買斷購入實測，不代表其他情境已全面驗收。
- 頁面改為月訂閱在前、買斷在後；英文名稱 **Monthly subscription**。ASC 月訂閱
  英文在地化名稱亦已保存，表格讀回核對一致；價格、供應、繁中文案未改，未提交審查。
- 同步、恢復購買、管理訂閱與刪除會員收進右上角「⋯」。有效月訂閱保留效期及
  Auto-renewal 狀態，點選會開 Apple 管理頁；Sandbox 顯示效期時間以便加速週期驗收。
- Membership／StoreKit 23 項通過；包含測試退款入口的 Debug 真機建置通過，已重新
  由 Xcode 安裝啟動。測試入口只在 DEBUG、Sandbox 啟動及已驗證 Sandbox 買斷時提供，
  使用 Apple `beginRefundRequest`，不由本機或人工修改付費權益。
- 使用者已確認送出沙盒退款。退款成功仍須以已驗證撤銷交易／REFUND 及會員回到
  Free plan 為準；單次通知 HTTP 200 或退款申請送出，不當作退款完成。
- 19:10 台灣時間只讀查核：Apple `getTransactionInfo` 新簽章交易仍未撤銷，
  `getRefundHistory` 為空，通知歷史只有買斷的 ONE_TIME_CHARGE／SUCCESS。實機 console
  同時有 Apple 退款表單 cancelled 與 unknown error，因此退款**尚未完成驗收**。
  可先切換已建立且尚未購買的台灣 Sandbox 帳號測 NT$10 月訂閱，不把帳號切換當退款。
  期間手機曾呼叫會員刪除再建立新會員，後端依 Apple 仍有效的買斷認回權益；這也確認
  刪除會員資料不會退掉 Apple 購買。代理未手動刪除資料或清空 ASC 購買歷史。

## 最新方案決策與帳號狀態 — 2026-09-21

同日後續權益更新：月訂閱與買斷都包含移除 banner、日曆及每日一次免看廣告 AI 生成。
買斷取得目前權益的永久資格；兩者並存優先顯示買斷，不再提供重複月訂閱新購，仍保留
Apple 訂閱實際狀態與管理入口，不代為取消。每日一次共用，免費初始一次與額外廣告
規則不變。有效買斷不會因訂閱到期失去日曆。颱風功能仍延至 1.8.0，其未來買斷資格未定
（2026-09-28 擁有者已決定：1.8.0 起月訂閱與買斷都包含臨時放假規則，免費不含；
Sandbox 會員服務隨此重新部署，正式會員服務須在 1.8.0 發布前部署）。
本次 Sandbox 後端已更新日曆權益，ASC 買斷中英說明已保存並讀回核對，詳見下一節；
真機購買／恢復與實際會員往返仍未因此自動通過。

| 商店 | 月訂閱 | 非消耗型買斷 |
| --- | --- | --- |
| 美國 | US$1／月 | US$10 一次 |
| 台灣 | NT$10／月 | NT$100 一次 |

使用者已取消年訂閱優惠方案。此表是最新指定且已保存／重讀核對的 ASC 價格，取代
9/16 三方案與舊買斷價。App 仍以 StoreKit 回傳價格顯示，不在 App 硬寫金額。

9/21 ASC 實際完成結果：

- 月訂閱 `6812814060`：已保存並重讀核對 **US$1／月、NT$10／月**；供應確認僅
  **美國＋台灣，共 2 地區**，未來新地區自動開放 OFF。
- 買斷 `6812814810`：已保存並重新開啟「目前價格」核對 **美國 US$10、台灣 NT$100**。
  美國基準價從 US$5 改為 US$10，需要透過 ASC 的全球基準價格調整；Apple 因此重算
  其他自動管理地區價格，再另設台灣固定 NT$100。畫面確認手動調整區為台灣 1 地區、
  其餘 174 地區自動群組中的美國價格為 US$10。商品主頁已保存供應僅 **美國＋台灣，
  共 2 地區**，未來新地區自動開放 OFF。主頁重新載入後供應仍為 2 地區且儲存鍵停用，
  已確認保存完成。
- 年訂閱 `6812814314`：已執行「停止銷售」，完成後重讀供應管理為 **0 個國家或地區**。
  商品／交易 ID 保留供歷史交易驗證與恢復，停售不當作退款或已到期。
- 美國以外、台灣以外的自動換算價格只是 Apple 價格表設定，**不是已定案售價，也未開放供應**。
  上述兩地價格可獨立設定；台灣買斷使用手動指定價，不跟隨美國基準自動換算。
- 上述更新未提交 App Review、未發布商品或啟用正式會員收費；真機 `Product.products`
  的本地價格、購買及後端認回仍待驗收。後續買斷日曆的 Sandbox 最小部署見下一節。

9/21 使用者最新確認「兩個沙盒帳號都搞定了」，附圖清楚列出台灣與美國各 1 筆，
因此 **台灣、美國兩個 Sandbox 測試帳號皆已建立**。截圖標題／總數仍顯示 1，與兩列
資料不一致；以使用者確認及實際兩列為這次建立完成的證據，不用標題數字否定結果。
不在 repo 記錄 Email／密碼。帳號建立不代表已登入手機；真機商品讀取、App Attest、
購買與會員認回仍待驗收。

帳號盤點歷史：9/17 截圖曾列兩個帳號；9/21 較早讀取曾先空列表、再只列台灣 1 筆，
並準備美國建立表單。這些中間狀態已由上述最新確認取代，不是目前阻擋，也不推論帳號曾被刪除。

## 買斷日曆權益部署與商品文案 — 2026-09-21

- 獨立 Sandbox 已部署 revision **`rainyclock-membership-sandbox-00004-kkd`**，
  讀回確認 100% 流量。使用既有上線映像 `dfe8952b…` 衍生最小變更，僅將
  `service.js` 的 calendar 權益由 `subscriptionActive` 改為 `lifetimeActive || subscriptionActive`；
  沒有將工作目錄其他 session 的未提交變更整包部署。
- 新映像 digest：`sha256:004d14c956c588bbd3fbbe377c36165689a0129f343afbf09fcffe1d0bc915e6`。
  Cloud Build ID：`d0c8b26e-b54b-44cc-bfe3-df0efa725e1d`；衍生映像內 5 項驗證通過，
  包含買斷退款與訂閱到期情境。
- 部署後 `/health` 200、`membershipEnabled=true`，未授權 `POST /v1/membership/status`
  回 401；GET 該路由回 405 為方法限制。Apple／App Attest／session 驗證與
  `TTS_DISABLED=1` 沿用，沒有開啟 AI 或廣告流量，也沒有重新部署正式 weather 服務。
- 雲端紀錄：`/tmp/rainyclock-lifetime-calendar-cloud-build-20260921.log`、
  `/tmp/rainyclock-lifetime-calendar-sandbox-deploy-20260921.log`。
- ASC 買斷商品 `6812814810` 的英文／繁中說明已保存並重新讀取表格核對如下；價格與
  美台供應範圍不變，未送審或發布。舊不含日曆的 9/16 文字留在歷史段，已不適用。

| 語言 | 顯示名稱 | 最新已保存說明 |
| --- | --- | --- |
| English | One-Time Purchase | Remove banners. Calendar + 1 ad-free AI creation/day. |
| 繁體中文 | 買斷 | 移除 banner，含日曆功能與每天 1 次免看廣告的 AI 鈴聲生成。 |

## 已建立的資源

| 項目 | 實際設定 |
| --- | --- |
| Google Cloud 專案 | `rainyclock`（510427696731），已啟用計費 |
| 區域 | 台灣 `asia-east1` |
| Firestore | 命名資料庫 `membership-sandbox`，Standard／Native，刪除保護開啟 |
| Cloud Run | `rainyclock-membership-sandbox`，revision `rainyclock-membership-sandbox-00004-kkd`，獨立入口 `node membership/server.js` |
| 測試網址 | `https://rainyclock-membership-sandbox-510427696731.asia-east1.run.app` |
| 執行身分 | `rainyclock-membership-sandbox@rainyclock.iam.gserviceaccount.com` |
| Firestore IAM | `roles/datastore.user`，條件限定上述命名資料庫 |
| Secret Manager | `membership-sandbox-identity` v1，台灣區保存；只有專用執行身分取得此 secret 的讀取授權 |
| Apple IAP secret | `membership-sandbox-apple-iap` v1，`asia-east1` 保存，專用執行身分可讀；掛載 `/secrets/apple/SubscriptionKey.p8` |
| 容量 | 1 CPU、512 MiB、min 0／max 1、concurrency 10、請求 timeout 120 秒 |
| 狀態 | **公開 HTTPS invocation、`MEMBERSHIP_ENABLED=1`、`TTS_DISABLED=1`**；會員操作仍強制 Apple／App Attest／session 驗證 |
| AI 成本設定 | `DAILY_TTS_LIMIT=20`，目前 AI 停用且服務帳號未授予 Vertex 使用權 |
| 資料庫驗證 Job | `rainyclock-membership-db-check`，手動執行、無排程、無自動重試 |

既有 `rainyclock-weather-proxy` 沒有重新部署，仍是 `rainyclock-weather-proxy-00012-win`。
一般 iOS／Release 的 `MembershipServiceURL` 保持空白。未修改 Android、未送審或發布。

手機／web 直接存取 Firestore 採 deny-all rules；server SDK 另由 IAM 控制。
已部署 7 組 TTL 欄位並移除其索引，音訊 `generationResults.pcm` 亦不索引。
7 組 TTL 已查核全部 `ACTIVE`；過期認證仍由程式即時拒絕，不依賴 TTL 刪除時間。

專用入口只有 `/health` 和 `/v1/membership/*`；不提供匿名 `/v1/tts`、weather 或公開維護路由。
`/health` 只表示程序存活／配置是否啟用，不表示 Apple、Firestore 或廣告端到端成功。
Cloud Run 外部 `/healthz` 實測被 Google 前端攔截，因此使用 `/health`。
啟用時 challenge 每執行個體整體限制 60 次／分鐘，不能靠輪換 IP 或 key 繞過；
但重啟會重置，**不是持久的每日費用上限或正式分散式限流**。

## Apple 金鑰與 API 接線

- 使用者已建立 IAP key `RainyClock Membership Sandbox`。下載後已驗證、妥善保存於
  repo 外的本機位置，並存入上述 Secret Manager v1；私鑰不寫入 Git、App、映像或紀錄。
  **名稱不限制金鑰只能用於 Sandbox**；測試環境限制由後端配置及驗證實施。
- 已配置 `MEMBERSHIP_APPLE_KEY_PATH=/secrets/apple/SubscriptionKey.p8`、key ID 與 issuer。
  Team ID `MQJ88U9NAJ`、Bundle ID `com.shukaihu.RainyClock`、App ID `6780500386`。
  公開 Apple roots 位於 `weather-proxy/membership/certificates/`，來源及 SHA-256 見該目錄。
- 此服務使用 `MEMBERSHIP_APPLE_ENVIRONMENT=Sandbox`、
  `MEMBERSHIP_ATTEST_ENVIRONMENT=development`、`MEMBERSHIP_NAMESPACE=membership_sandbox_v1`。
  固定測試 cutover 應為 `2013-08-01T07:00:00Z`，因 Apple Sandbox 的原始取得日期固定為該日；
  正式環境不可沿用。舊額度遷移仍需另外確認，不能自動送新次數或清除本機餘額。
- 啟用 revision `00003-vsr` 沿用前一版容器映像，已允許公開 HTTPS invocation；
  Cloud Run IAM 不再攔截手機及 Apple 回呼，購買／會員操作所需的 Apple 簽章、
  App Attest／session 驗證仍強制執行；health 與 challenge 可公開取得。
- 真實 Apple Sandbox API `getNotificationHistory` 最初查詢已認證成功、當時回傳空歷史；
  API 憑證可用不代表裝置 App Attest 或購買已成功，通知另有以下實際送達驗證。
- ASC 已保存並重讀確認 Sandbox Notifications V2 URL：
  `https://rainyclock-membership-sandbox-510427696731.asia-east1.run.app/v1/membership/apple/notifications`。
  Production notification URL 保持空白。等待設定傳播後，15:27:51Z 的
  `requestTestNotification` 已成功；15:28:28Z 查詢結果為 **`sendAttempts=SUCCESS`**，
  Apple 記錄送達時間 `1789572471802`（Unix 毫秒）。真實 `signedPayload` 已通過官方
  `SignedDataVerifier` 與線上憑證查核：`environment=Sandbox`、
  `bundleId=com.shukaihu.RainyClock`、`notificationType=TEST`。
  Cloud Run 亦確認 `2026-09-16T15:27:52.124678Z` 的 Apple TEST POST 回 **200**，
  處理 revision 為 `00003-vsr`；Apple 狀態、真實簽章及伺服器接收三者已核對，
  **Apple Sandbox TEST 通知串接已通過**。
  結果：`/tmp/rainyclock-membership-apple-notification-result.json`（不保存 JWS 或測試 token）；
  Cloud Run 證據：`/tmp/rainyclock-membership-apple-notification-cloud-log.json`。
  先前至 15:21Z 的四次 `4040007` 為傳播等待期歷史，已不再是阻擋項。
  TEST 通知不代表實際 IAP 交易，預期不建立購買／額度 ledger；購買、續訂與退款通知仍待驗收。

Debug 真機使用 Sandbox + development App Attest；**TestFlight 使用 Sandbox + production
App Attest**，不可直接混用目前的裝置 key／環境。新帳號第一次 history 查詢若回
`4040010`，目前會拒發 session；不能把查核失敗解讀成免費會員。

## App Store Connect 商品草稿 — 2026-09-16 歷史盤點

以下為 9/16 已保存的設定；價格、年方案及買斷不含日曆文案已被 9/21 決策取代，
保留商品 ID 及舊文字供相容與追查，不能複製為目前上架文案。

本輪初次盤點為零，後續已建立以下草稿。訂閱群組為 `RainyClock Plus`（ID `22390056`）；
月／年均已明確設為 **level 1**，已修正初建時的 1／2 分級。

| 商品 | 類型／週期 | Product ID | Apple ID | 訂閱級別 | 美國測試價 |
| --- | --- | --- | --- | --- | --- |
| Monthly | 自動續訂／1 個月 | `com.shukaihu.RainyClock.plus.monthly` | `6812814060` | 1 | US$1／月 |
| Yearly | 自動續訂／預付 1 年 | `com.shukaihu.RainyClock.plus.yearly` | `6812814314` | 1 | US$10／年 |
| RainyClock One-Time Purchase | 非消耗型買斷 | `com.shukaihu.RainyClock.banner.lifetime` | `6812814810` | 不適用 | US$5 一次 |

使用者明確批准「先只開美國供 Sandbox 測試；其他地區不開放，對應價仍待確認」。
三個商品的上述價格與 **USA only** 可售地區均已儲存、重讀核對；未來新地區自動開放均為 OFF。
年方案是預付 1 年，沒有設定「12 個月承諾、逐月付款」。Apple 自動產生的非美國對應價
**不是已批准的正式售價**，那些地區也不可售；正式發布前仍須確認定價與可售範圍。
最初因跨區價格未決而取消的價格視窗是歷史，後續已依本次美國限定測試授權完成設定。

9/16 當時的英文與繁體中文共六筆本地化已儲存並重讀驗證（歷史，買斷權益文案已過時）：

| 商品 | 語言 | 顯示名稱 | 描述 |
| --- | --- | --- | --- |
| 買斷 | English | One-Time Purchase | Remove banners. One ad-free AI ringtone creation daily. |
| 買斷 | 繁體中文 | 買斷 | 移除 banner，每天 1 次免看廣告的 AI 鈴聲生成；不含日曆功能。 |
| 月訂閱 | English | Monthly | Remove banners. Calendar + 1 ad-free AI generation/day. |
| 月訂閱 | 繁體中文 | 月訂閱 | 移除 banner，含日曆功能與每天 1 次免看廣告的 AI 鈴聲生成。 |
| 年訂閱 | English | Yearly | Remove banners. Calendar + 1 ad-free AI generation/day. |
| 年訂閱 | 繁體中文 | 年訂閱 | 移除 banner，含日曆功能與每天 1 次免看廣告的 AI 鈴聲生成。 |

群組英文／繁中兩筆本地化也已儲存並重讀核對：群組名稱均為 `RainyClock Plus`，
使用 App 名稱 `Rainy Clock`。

UI 顯示「準備提交」；**均未提交或發布**。審查截圖尚未提供，家庭共享保持關閉。
這些是 Sandbox 測試準備；真機 `Product.products` 與購買仍未驗收，需使用者自己的 Sandbox 帳號。

## iPhone 測試方式（9/21 晚間更新）

- 19:20 專用 Debug Sandbox 已安裝到 iPhone 16 Pro；停止 Xcode 後以零額外參數／
  環境變數獨立啟動成功，測試後端 challenge 200。Configuration／Membership／StoreKit
  35 項通過；實機建置及非 DEBUG 隔離檢查通過。台灣帳號價格與月訂閱仍待手機驗收。
- Xcode 選 `RainyClock Membership Sandbox`，目的地選 iPhone 16 Pro 真機。
- scheme 的 Run 使用專用 **Debug Sandbox**，StoreKit Configuration 為 None。
  測試端點與廣告隔離由此安裝版本的編譯組態決定，已移除舊 launch 參數／環境變數；
  **從手機桌面重新開啟也保持有效**。Archive 仍 Release，不把測試端點帶入正式版。
  9/21 使用者及最新截圖已確認台灣、美國兩個 Sandbox 帳號建立。
  接下來由使用者在手機登入對應商店帳號，憑證自行保管及輸入；
  同時核對該商店的最新商品價格與供應狀態；
  再驗收真機商品讀取、身分同步及購買，不能以帳號已建立代替驗收。
- 進「設定 → 其他 → 會員與方案 → ⋯」，先同步會員，再購買／恢復／管理訂閱。
  換沙盒帳號後必須明確同步，才能依 Apple 驗證的新身份取代舊會員快取。
  美國／台灣商品隨 Storefront 更新重載，會員同步失敗也不阻止商品重新取得。
- session、權益快取及 App Attest key 按測試網域與一般版本隔離；不改設定或刪已排程鬧鐘。
- 本 scheme 明確停用所有廣告請求與 ATT／廣告同意流程。要驗證 LevelPlay 時，須另行確認
  官方 test device／Test Suite、S2S 私鑰與 callback，再加入受控測試入口。
- 真機買斷已取得使用者與雲端證據；月訂閱、退款、換機及 AI／廣告仍需分項驗收，
  最新實測結果見文件上方，不能以 health／建置通過替代購買驗收。

## 驗證紀錄與剩餘工作

2026-09-21 iPhone 畫面排查與重新安裝歷史（19:13 後已改用上述持續有效的測試組態）：

- 使用者截圖顯示 `Plans are not available for purchase yet`、無價格、灰色按鈕及 banner。
  此提示僅在 `MembershipManager.isConfigured == false` 出現；`start()` 直接返回，
  尚未呼叫 `Product.products`。不能由此判定商品、Sandbox 帳號或首次會員驗證失敗。
- 實機需使用 **Membership Sandbox** 的 Debug 啟動參數與網址；**Membership Local**
  僅在模擬器有效。從手機桌面重新開啟也不會保留 Xcode scheme 的參數／環境變數。
- 最新程式（包含買斷日曆權益與路線收合）已完成 Debug 實機建置並安裝 iPhone 16 Pro；
  `/tmp/rainyclock-sandbox-device-build-20260921.log`、
  `/tmp/rainyclock-sandbox-device-install-20260921.json`。Cloud Run health 回傳
  `ok=true, membershipEnabled=true`。首次啟動被手機鎖定阻止；使用者解鎖後於 18:50
  以 Sandbox 參數與網址成功啟動，紀錄
  `/tmp/rainyclock-sandbox-device-launch-20260921-unlocked.json`。
  此時尚未宣稱看到價格、會員認回或購買成功。
- 18:51 後續使用者截圖有價格、無 banner，但 Apple 認證 sheet 顯示 `Environment: Xcode`。
  因先前 Xcode 選擇 Local，直接用 devicectl 傳入 App 參數未切掉殘留的本機 StoreKit 環境；
  價格載入與 banner 消失不能單獨作為真正 Sandbox 的證據，認證 OK 也不是購買。
- 已重新開啟 Xcode 專案以載入新增 scheme，從 Local 切到 **RainyClock Membership Sandbox**，
  UI 確認 Run → Options → **StoreKit Configuration = None**，並由 Xcode Run 成功啟動
  **Shu-Kai Hu 的 iPhone16Pro**（Xcode 顯示 Running、PID 91494）。這是環境設定及啟動
  驗證，還沒有宣稱 Apple Sandbox 認回、商品或購買端到端通過。
- 接著需由使用者在 Apple sheet 確認 Sandbox，再完成同步（成功後仍可為 Free plan），
  實際購買後才能驗證付費權益。參考 Apple 的
  [StoreKit 測試設定](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)
  與 [Apple 工程師的實機 Sandbox 步驟](https://developer.apple.com/forums/thread/805806?answerId=864483022)。

2026-09-21 後續買斷日曆權益驗證：

- 後端 domain／HTTP **43 通過、0 失敗、1 跳過**；跳過項需要未啟動的 Firestore Emulator，
  不宣稱本批跑過 Emulator。紀錄：`/tmp/rainyclock-lifetime-calendar-backend-20260921.log`。
- 實際部署衍生映像內另有 5 項（含退款／到期）通過，Sandbox 部署與 HTTP 結果見上節。
- 本輪 iOS **61 通過、0 失敗**，Simulator App 建置完成：Membership、Configuration、
  StoreKit 與 AlarmSchedulingSettings 第一批 55 項，MembershipScheduling 第二批 6 項。
  紀錄：`/tmp/rainyclock-lifetime-route-ios-tests-20260921.log`、
  `/tmp/rainyclock-lifetime-scheduling-tests-20260921.log`。下方 28 項是稍早移除年方案批次。
- 專用 `RainyClockMembershipTests`／iOS 26.2 視覺驗收已完成：Time／Route 卡片一致，
  Home／Work 各自 sheet 可開關、輸入地址後返回值保留；步行即選即保存，地圖顯示
  94 分鐘／6.1 km，兩端位置正確且不被底部分頁遮擋。Route 沒有天氣區，Alarm 天氣仍在。
  本輪未驗證 autocomplete 建議點選，不宣稱所有路線操作全面驗收；未安裝實機。
- ASC 最新買斷中英說明在頁面重新載入後再次讀回確認，持久保存通過，未送審。
  以上均不代表 iPhone Sandbox 登入、購買或後端會員端到端已通過。

2026-09-21 稍早方案精簡本機驗證（新權益變更前）：

- iOS MembershipStoreKit／Membership 重點測試 **28 項通過、0 失敗**，
  `xcodebuild TEST SUCCEEDED` 並完成 Simulator App 建置。
  `/tmp/rainyclock-membership-two-plans-tests-20260921.log`；
  `/tmp/RainyClock-Membership-Pricing-DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.21_17-09-00-+0800.xcresult`。
- 後端方案／權益測試 **8 項通過、0 失敗、0 跳過**：
  `/tmp/rainyclock-pricing-domain-20260921.log`。
- 當時定價批次未重新部署後端或完成真機購買；後續買斷日曆 Sandbox 部署見上節。
  ASC 年方案停止銷售已核對，月／買斷價格與供應結果見本文件上方。

2026-09-16 雲端及本機驗證歷史：

- 完整 Node＋官方 Firestore Emulator：151 通過、0 失敗、0 跳過。
  `/tmp/rainyclock-membership-staging-all-tests-20260916.log`。
- 改 `/health` 與全域 challenge 上限後，針對入口測試 18 項全過。
  `/tmp/rainyclock-membership-staging-health-challenge-tests-20260916.log`。
- iOS focused 27 項通過；補廣告防護後，配置／廣告 9 項通過。
  `/tmp/rainyclock-membership-sandbox-focused-tests.log`、
  `/tmp/rainyclock-membership-sandbox-ad-gate-tests.log`。
- 一般 unsigned Release 建置成功：1.7.0（29）、會員 URL 空白、執行檔沒有 Sandbox 旗標／
  測試網址、未嵌入 `.storekit` 或測試 bundle。
  `/tmp/rainyclock-membership-sandbox-ad-gate-release-check.json`。
- 真雲端 Firestore 未授權 GET／PATCH 都是 403；專用 Job 用真實執行身分的 8 個並行
  transaction 全部完成，counter 正確為 8，Job exit 0，並清理自己的隨機測試紀錄。
  Execution `rainyclock-membership-db-check-hzlg4`；
  `/tmp/rainyclock-membership-sandbox-db-check-result.json`。
  最初探測不存在的 `(default)` DB 回 NOT_FOUND，使該輪檢查誤判失敗；改正檢查後通過。
  這個結果不是「另一個既存 DB 拒絕存取」的證明；IAM 限定範圍已另外讀取核對。
- Cloud Run 部署 artifact digest：
  `sha256:dfe8952b833264adeeb6af8e02a92541751174a974e0e47513db791c81e0ceeb`。
  `/tmp/rainyclock-membership-sandbox-cloud-build-v2.log`、
  `/tmp/rainyclock-membership-sandbox-deploy-v2.log`。
- 啟用後 HTTP：`/health` 200 且 `enabled=true`、challenge 200、缺少 session 401、
  無效 Apple 簽章 401、舊 `/v1/tts` 404。拒絕路徑通過不等於真機購買成功。
- 建立初期的歷史檢查（revision `00002-6bc`、private／`MEMBERSHIP_ENABLED=0`）：
  授權 `/health` 200、未配置 membership 503、匿名語音路由 404；無 IAM 認證請求 403。
  此關閉狀態已由本次 `00003-vsr` 啟用取代，保留舊紀錄供追查：
  `/tmp/rainyclock-membership-sandbox-http-check.json`。

已取得真機美國買斷、台灣月訂閱、development App Attest／會員與購買往返證據。
還需：審查截圖、續訂偏好／到期／退款通知與兩台裝置認回、
TestFlight／正式版 production App Attest、
LevelPlay 官方測試 S2S、AI 實際生成與失敗取回、受 IAM 保護的刪除維護排程及告警。
正式啟用另需核准舊額度移轉、可信限流／費用告警、隱私揭露與正式資源設定；
不能將模擬器或測試資料庫通過宣稱為正式收費已完成。

官方參考：[Firestore 資料庫 IAM](https://docs.cloud.google.com/firestore/native/docs/manage-databases#configure_per-database_access_permissions)、
[命名資料庫 rules 部署](https://firebase.google.com/docs/rules/manage-deploy#use_the_rest_api)、
[Apple Sandbox 原始購買日](https://developer.apple.com/documentation/storekit/apptransaction/originalpurchasedate)、
[Apple IAP 金鑰](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/generate-keys-for-in-app-purchases)。
