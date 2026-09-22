# 會員領域資料與本機驗證 / Membership domain and local verification

此目錄提供會員、權益、每日／免費／獎勵額度與生成結果的實作。**本機測試成功不代表
Apple、LevelPlay 或正式 Firestore 已設定完成。** 使用者於 2026-09-16 後續授權後，
已建立獨立台灣 Sandbox DB，接入使用者建立的 IAP 金鑰並啟用測試 Cloud Run。
目前 revision `rainyclock-membership-sandbox-00004-kkd` 以舊映像最小衍生更新買斷日曆權益，允許公開 HTTPS
invocation；`MEMBERSHIP_ENABLED=1`、`TTS_DISABLED=1`，Apple／App Attest／session 驗證
仍強制執行。正式 weather revision `00012-win` 及一般 App 會員設定不變。
私鑰已驗證並保存於 repo 外及 Secret Manager `membership-sandbox-apple-iap` v1
（asia-east1），專用 SA 可讀，掛載 `/secrets/apple/SubscriptionKey.p8`。
金鑰名稱 `RainyClock Membership Sandbox` 不代表金鑰本身僅限 Sandbox；環境限制由後端實施。
當前資源及驗證結果見 [測試環境紀錄](../../docs/MEMBERSHIP-STAGING.md)。
完整 HTTP／Apple／App Attest 設定以專案會員文件與 `runtime.js` 為準。

## 最新商品決策 — 2026-09-21

同日後續決策：月訂閱與買斷都解鎖 banner 移除、日曆及每日一次 AI。買斷為當前權益的
永久資格、兩者並存時優先顯示，已有買斷不再允許重複月訂閱新購；不隱藏或自動取消
實際 Apple 訂閱，保留狀態與管理入口。額度不變；1.7.1 臨時放假的買斷資格本次未定。
本次新權益已以最小映像變更部署至 Sandbox `00004-kkd`，映像內 5 項驗證通過；
ASC 買斷中英說明已保存並讀回，未更新正式會員服務。確切驗證與部署證據見 staging。

只提供月訂閱與非消耗型買斷：美國 US$1／月、買斷 US$10；台灣 NT$10／月、買斷 NT$100。
不再提供年訂閱優惠方案；歷史年方案交易仍須依 Apple 真實狀態驗證，不以停售當作退款。
9/21 ASC 已保存並重讀核對上述價格：月／買斷供應只有美國＋台灣共 2 地區，年方案
已停售、0 地區，未來地區自動供應 OFF。買斷美國基準改為 US$10，台灣另設手動固定 NT$100；
其他未供應地區的自動價格不算產品定案。App 顯示 StoreKit 當地價格，
證據見 [staging](../../docs/MEMBERSHIP-STAGING.md)。以下 9/16 商品設定僅是歷史。
正式會員服務尚未開放，未送審或發布；本次只更新上述獨立 Sandbox 後端。

## 已確認規則

- 付費者每天一次，依會員記錄中的本地時區午夜更新，不累積；同時買斷與訂閱共用一次。
- 有效買斷持續提供 banner 移除、日曆及每日 AI；有效月訂閱享有相同當前權益。
  買斷優先作為顯示層級；仍保存實際訂閱／續訂資料。臨時放假維持延後，其未來買斷資格未定。
- 生成結果可靠保存到後端後才扣次數；失敗退回原本的每日、免費或廣告額度。
  播放手機已保存的音檔不扣次數。同一請求重新下載不扣次數。
- 到期時不清除手機設定或既有排程；沒有有效買斷等日曆權益時，App 下次安全重排才
  套用基本規則。訂閱到期但買斷有效時仍可使用日曆。
- 免費者為初始一次與獎勵廣告，不新增每日額度（2026-09-16 最新決定）。付費期間保留尚未使用的原免費
  額度但不拿來取代「每日一次之後每次需廣告」；返回免費方案時才再提供。

## 目前方案與續訂狀態

`entitlements` 另提供 `subscriptionProductId`（目前有效商品）、
`subscriptionAutoRenews`（`true`／`false`／未知 `null`）與
`subscriptionRenewalProductId`（下一期已設定的商品）。到期、退款或沒有有效訂閱時，
三個欄位均為 `null`；App 不應將它們解釋為已購買或可用的方案。取消自動續訂仍保留
已付款期間的權益，到期日沿用 `subscriptionExpiresAt`；續訂開啟時，UI 可標示預計續訂日。
即使歷史年方案的轉換尚未生效，目前商品與下一期商品也要分開，不能先把目前方案標成下一期方案。

Apple Notifications V2 與 Server API 對帳都驗證 nested renewal JWS 後才讀取
`autoRenewStatus`／`autoRenewProductId`；沒有可信資料顯示未知，不自行預設開啟或關閉。
交易、狀態與 `renewalSignedAt` 分別合併，同交易重新簽章不會清空已驗證續訂資料；
延遲或重複通知不會讓最新偏好倒退。手機只提供 Apple「管理訂閱」入口，後端不接受
手機指定續訂布林值。真實 Sandbox API `getNotificationHistory` 最初認證成功、歷史為空。
ASC Sandbox 通知網址已保存（正式 URL 空白）；設定傳播後，15:27:51Z TEST 請求成功，
15:28:28Z 狀態為 `sendAttempts=SUCCESS`。官方 SignedDataVerifier 與線上憑證查核已驗證
真實 signedPayload 為 Sandbox／`com.shukaihu.RainyClock`／TEST。
Cloud Run 亦核對 `15:27:52.124678Z` 的通知 POST 回 200（revision `00003-vsr`），
Apple Sandbox TEST 通知串接已通過。
先前四次 `4040007` 已解除。結果存於 `/tmp/rainyclock-membership-apple-notification-result.json`
（不含 JWS／token）。TEST 預期不建立購買／額度 ledger，不代表購買交易對帳通過；
App Attest、購買與實際交易通知仍待真機驗收。9/21 使用者最新確認與截圖兩列已證實
台灣、美國 Sandbox 帳號皆已建立；畫面總數與兩列不一致，不以總數否定建立結果。
憑證由使用者持有，不代表手機登入或購買已通過。
Cloud Run 證據另存 `/tmp/rainyclock-membership-apple-notification-cloud-log.json`。

9/16 歷史設定（價格／年方案已被 9/21 決策取代）：ASC 從零商品建立月／年／非消耗型買斷草稿。
月／年同屬 `RainyClock Plus` 群組 `22390056`、均為 level 1，週期分別 1 個月／1 年；
完整 Apple ID 見 staging 紀錄。經使用者明確批准，Sandbox 準備已儲存並核對
月 US$1／預付年 US$10／買斷 US$5，三者 USA only、未來新地區自動開放 OFF；
未設 12 個月承諾逐月付款。非美國對應價由 Apple 產生，不是已批准正式售價，其他地區不可售。
英文／繁中六筆商品與兩筆群組本地化已儲存並重讀核對；群組名稱 `RainyClock Plus`、
使用 App 名稱 `Rainy Clock`。UI「準備提交」，均未提交或發布，
審查截圖未提供、家庭共享關閉。真機 `Product.products` 與購買仍未驗收。

依據：[Apple 續訂簽章欄位](https://developer.apple.com/documentation/appstoreserverapi/jwsrenewalinfodecodedpayload)。

## 時區與並行

`members/{id}` 是所有裝置共享的序列化點。伺服器時間決定額度，不採用手機日期。
時區須為有效 IANA 值。變更先保存為 `pendingTimeZone`，不能縮短已承諾的當前窗口；
僅在窗口結束後才生效，且兩次時區生效至少相隔 24 小時。初次選定亦啟動 24 小時
限制。最後一次請求的候選時區保留至可生效的邊界，狀態提供 `timeZoneChangeNotBefore`。
這是防止快速切換時區多領的實作限制；不是用 App Attest、IP 或 GPS 證明所在地。
同一時區的 DST 變化仍依真正的本地午夜處理，不硬加 24 小時。

獎勵回呼確認使用 `quota.rewardGrantCount` 的單調遞增序號，不比較可用餘額。
每個首次驗證成功的唯一廣告事件增加一次，即使另一裝置已花掉那次獎勵仍可確認
回呼曾入帳；重複事件不增加。這是會員範圍的序號，會員刪除後的新 ID 重新起算。

## 信任邊界與資料

`service.js` **只接受已由驗證層驗證的 Apple 交易與廣告回呼**，不得將 HTTP body
原樣交給 `recognizeMember`、`applyVerifiedPurchase` 或 `creditVerifiedReward`。
Apple 身分以環境、App、App transaction ID 的 HMAC 對應隨機會員 UUID；測試與正式
隔離。新購買須綁定已驗證的 App transaction ID 或此會員的 `appAccountToken`。

相對於 `membershipNamespaces/{namespace}`：

| 路徑 | 內容 |
| --- | --- |
| `identities/{hmac}` | 身分對應，刪除後保留最小防濫用記錄 |
| `members/{id}` | 內部 ID、購買用 UUID、計數器、時區窗口、移轉／刪除狀態 |
| `members/{id}/purchases/{chainHmac}` | 每條原始購買鏈最新的已驗證狀態 |
| `purchaseOwners/{hmac}` | 防止同一交易鏈綁至另一身分 |
| `notifications/{hmac}` | Apple 通知去重；刪除會員時去除會員 ID |
| `members/{id}/days/{windowId}` | 已用及預留每日次數 |
| `members/{id}/generations/{requestHmac}` | 請求內容 HMAC、資金來源、租期與終態 |
| `members/{id}/generationResults/{requestHmac}` | 最多 480,000 bytes 的 PCM、取回期限與情緒 ID |
| `rewardEvents/{hmac}` | 簽章驗證後的廣告事件去重與身分 HMAC |
| `rewardProofs/{hmac}` | 已驗證平台簽章原始欄位拼接內容的指紋去重，防止欄位邊界重解後再次授予 |

Firestore 交易同時鎖定預留與計數；只有取得工作的執行個體呼叫生成。成功音訊保存與
扣額度在**同一次交易**完成。若提交成功但回應遺失，重試取回已保存結果；若結果沒有
保存成功，保留至五分鐘租期到期，再以終止狀態退回額度。同一請求 ID 永不自動重新
呼叫生成；使用者明確重試新一次生成才建立新 ID。新請求與狀態同步會清理失聯預留，
即使重裝後遺失原請求 ID 也不會永久卡住額度。

LevelPlay 的 `timestamp` 固定為 `YYYYMMDDHHMM`；本次官方 Dashboard callback
已與 Cloud Run 接收時間比對，確認使用 UTC。程式嚴格驗證日期與時間，不接受非法日期
進位或回落為 Unix 秒／毫秒，並保留九天有效期及最多五分鐘的未來時間容差。
簽章仍使用原始 timestamp 字串，依官方公式拼接欄位後驗證 MD5，不使用轉換後的時間值。
廣告入帳同時以平台 event ID 及已驗證簽章內容的 proof 指紋做原子去重；同一事件即使
以較新時間重新簽章重送，也只授予一次獎勵。格式與簽章依據見
[LevelPlay 官方 callback 文件](https://docs.unity.com/en-us/grow/levelplay/platform/settings/event-handlers)。

結果是 24 小時的重試暫存，**不是音檔跨裝置雲端同步**。`generationResults.expiresAt`
需要部署 Firestore TTL；TTL 非即時刪除，因此程式亦在 24 小時期限後拒絕下載。
PCM 欄位關閉索引。輸入的文字不保存於會員紀錄；請求內容只存 HMAC，不能用一般
字典推算未加密雜湊。生成完成／失敗的最小去重紀錄保留，避免舊 ID 再次扣費。

`firestore.indexes.json` 同時設定 `authChallenges.ttlAt`、`authSessions.ttlAt` 與
`authChallengeLimits.expiresAt`、`authAppleProofs.ttlAt` 的 TTL，並關閉這些欄位索引。這些規則用來清除已
過期的工作階段、一次性 challenge 及內部節流紀錄，**不是即時撤銷／認證機制**；
Firestore TTL 刪除可能延遲，認證層仍依伺服器時間拒絕過期 challenge／session，
亦會檢查 challenge 是否已用及會員刪除狀態。以上 TTL 設定尚未部署到正式資料庫。

`authDevices.ttlAt` 另外清理未完成的 bootstrap：建立／重新驗證時設定一小時期限，
成功建立 session 後清為 null，正常註冊裝置不由此期限刪除。重新驗證會保留原會員
連結至成功重新綁定，讓會員刪除可以找到中斷流程的裝置；新的 session epoch 會立刻
使舊 session 失效，不靠 TTL 等待撤銷。

所有 mobile/web SDK 讀寫由 `firestore.rules` 拒絕；Cloud Run server SDK 使用 IAM，
正式服務帳號仍須配置最小資料庫權限。規則不是對 server SDK 的 IAM 替代品。

新會員生成路由另有持久的上游成本上限：`DAILY_TTS_LIMIT` 預設每天 2,000 次實際
嘗試。固定 `membership_tts_cost_v1` namespace 讓同一資料庫中的 Cloud Run replicas、
Sandbox／Production 共用 Firestore 交易計數，成本日期使用伺服器 UTC 午夜，與使用者
本地每日權益分開。只有真正新生成會先預留成本；重播結果不增加。上游失敗可能已
計費，因此不退成本計數，但仍退回會員額度；成本上限拒絕時不呼叫上游、亦退回會員
預留。成本紀錄只含日期與總次數，TTL 為 90 天。舊 `/v1/tts` 原有成本保護另行保留，
不是這個新會員計数器的一部分，正式切換時必須一併檢視舊路由的使用與總預算。

## 舊額度移轉與刪除

2026-09-16 起，新會員初始免費生成改為一次；既存後端 ledger 不因政策預設改變而
重發或刪減額度。本機舊流程沿用原有 Keychain／UserDefaults 的已使用計數，免費餘額
為 `max(1 - used, 0)`；已使用數字不歸零、已獲得的廣告次數完整保留。已用過一次者
不會因更新、重裝或隔天取得新的初始次數。付費每日一次與廣告規則不變。

`migrationCutoverAt` 必須是固定、明確配置的上線分界，不能每次服務啟動使用現在時間。
Apple 原始取得日期早於分界或無法判定者不自動重新送免費次數。原裝置提供的免費／廣告
餘額只進入一次性 `quarantined` 紀錄，既不直接信任、也不覆寫手機餘額。現有 Keychain
記錄沒有可由伺服器驗證的證據，故正式切換前仍需決定一次性的補償／審核方式；尚未
完成移轉前保留舊免費流程，不能直接全面強制切換或讓舊使用者餘額歸零。

刪除先寫入不可使用的會員標記，再分批刪除購買、每日紀錄、生成音訊和裝置／工作
階段資料；標記為 `deletionCleanupState: pending`，維護工作可在中斷後補完。刪除後
仍保留不可逆的 keyed identity／purchase／reward 摘要、初始額度已領標記及目前窗口
已用額度，防止刪除重建多領或重放交易／廣告；不保留姓名、Email、原始 Apple 帳號、
文字或音訊。這些去重摘要仍屬需揭露的假名資料，不能宣稱完全匿名。
刪除會員**不會取消 Apple 訂閱**；取消須前往 Apple 管理訂閱。再次認回後可用新的
已驗證 Apple 狀態恢復仍有效的購買，但不重新贈送免費或當日額度。

## 正式啟用前設定表（測試部署另見 staging 紀錄）

下表從目前 `runtime.js`／`apple.js`／既有 proxy 程式整理。**填好環境變數或本機測試
通過仍不能直接打開正式會員服務。** 必須先在獨立測試配置完成真正的 Apple Sandbox
購買與認回、實體裝置 App Attest、Apple 通知，以及 LevelPlay 官方測試裝置的已簽章
回呼驗證，再取得另一次部署授權。測試用替身與 StoreKit `.storekit` 成功不能取代
這些平台連線驗證。正式環境不得接受 Xcode／LocalTesting 證明。

### 後端環境變數

| 變數 | 預設／必要條件 | 設定方式及注意事項 |
| --- | --- | --- |
| `MEMBERSHIP_ENABLED` | 只有字串 `1` 才啟用，其餘關閉 | 正式尚未驗證前維持關閉；打開後缺必要配置會拒絕啟動或請求，不降級成信任手機 |
| `MEMBERSHIP_FIRESTORE_PROJECT` | 否則使用 `GOOGLE_CLOUD_PROJECT` | 使用擁有者 Google Cloud 專案；先查已有資料庫與 API，不假設已建立 |
| `GOOGLE_CLOUD_PROJECT` | 既有語音／Vertex 專案 | 語音模組仍讀此值；另設 Firestore project 不會移動 AI 計費專案 |
| `MEMBERSHIP_FIRESTORE_DATABASE` | `(default)` | 指向已核准的 Firestore Standard 資料庫，不由程式自動建立 |
| `MEMBERSHIP_NAMESPACE` | `membership_sandbox_v1` 或 `membership_production_v1` | 不可將測試與正式指到同一 namespace；成本計數另固定共用 `membership_tts_cost_v1`，限同一 DB |
| `MEMBERSHIP_MIGRATION_CUTOVER` | 必填，可解析的固定 ISO 8601 日期時間 | 由正式移轉方案決定，包含時區；不能每次部署換成現在時間，否則新舊會員的初始額度分類會改變 |
| `MEMBERSHIP_IDENTITY_HASH_SECRET` | 必填，至少 32 字元 | 由 Secret Manager 提供高熵固定密鑰，不寫進 App／Git／log。HMAC 身分及去重依賴此值，輪替前必須有版本化移轉方案 |
| `MEMBERSHIP_BUNDLE_ID` | 必填 | `com.shukaihu.RainyClock`；Apple JWS、Server API 與 App Attest 必須一致 |
| `MEMBERSHIP_TEAM_ID` | 必填，10 位英數大寫 | App 開發團隊 ID，對應 App Attest 的 App ID，不是 App Store 數字 ID |
| `MEMBERSHIP_APPLE_ENVIRONMENT` | 必填，僅 `Sandbox`／`Production` | 兩種環境的交易、通知端點及資料隔離。禁止 `Xcode`／`LocalTesting` 連線到會員後端 |
| `MEMBERSHIP_APPLE_APP_ID` | Production 必填正整數 | App Store Connect 中 App 的數字 Apple ID；不是 Team ID／Bundle ID |
| `MEMBERSHIP_APPLE_ROOT_CERTIFICATES` | 必填，逗號分隔的絕對檔案路徑 | 掛載 Apple 官方信任根憑證，交官方 App Store Server Library 驗證；不能使用任意自簽根或跳過 online 憑證檢查 |
| `MEMBERSHIP_APPLE_KEY_PATH` | 上線與測試端到端都需要 | 掛載 App Store Server API 私鑰檔；不貼到 URL、App 或紀錄 |
| `MEMBERSHIP_APPLE_KEY_ID` | 與上項同時配置 | 對應 Server API 金鑰 ID |
| `MEMBERSHIP_APPLE_ISSUER_ID` | 與上兩項同時配置 | App Store Connect API 發行者 UUID。三項缺一時無法對帳，因此不能提供正常會員服務 |
| `MEMBERSHIP_ATTEST_ENVIRONMENT` | `production`；測試可明確 `development` | 必須與實體 App entitlement 及憑證環境相符；Production Apple 環境拒絕 development App Attest |
| `MEMBERSHIP_LEVELPLAY_PRIVATE_KEY` | 不設定則停用獎勵認領端點 | 與 LevelPlay 後台完全一致的非空白 S2S 私鑰，由 Secret Manager 注入；驗簽保留原值，不自行裁切空白或設定文件未規定的最小長度。實值不寫入 App／Git／log；不是 Unity Ads 的不同驗證協定 |
| `DAILY_TTS_LIMIT` | `2000` | 新會員上游嘗試的 Firestore 共用 UTC 日成本上限。必須為 1～1,000,000 整數；不是使用者的每日權益 |
| `TTS_DISABLED` | `1` 停止語音生成 | 保留既有停止開關；不因此停止基本鬧鐘或刪除會員設定 |
| `LEGACY_TTS_DISABLED` | `1` 停用舊 `/v1/tts` | 舊免費額度移轉尚未核准前不能直接打開此開關；切換時須避免舊路由繞過新額度及誤傷仍使用舊流程的用戶 |
| `FIRESTORE_EMULATOR_HOST` | 僅本機測試，例如 `127.0.0.1:8686` | 正式 Cloud Run 不設。完整 runtime 同時要求 `demo-` 開頭 project，避免測試誤連正式；fixture 測試另有專用 emulator project |

既有同一服務仍要求 `WEATHERKIT_TEAM_ID`、`WEATHERKIT_SERVICE_ID`、`WEATHERKIT_KEY_ID`、
`WEATHERKIT_PRIVATE_KEY`，並沿用 `PROXY_SHARED_SECRET`、`DAILY_UPSTREAM_LIMIT`、`PORT`
（預設 8080）。語音繼續使用 Cloud Run service account ADC，沿用 `VERTEX_LOCATION`
（`us`）、`VERTEX_ANNOTATE_MODEL`（`gemini-3.1-flash-lite`）、`GEMINI_TTS_MODEL`
（`gemini-2.5-flash-tts`）。`GOOGLE_ACCESS_TOKEN` 只是既有本機診斷覆寫，不應保存為
正式長期憑證。調整會員功能時應保留原服務的 WeatherKit／語音設定與授權。

### 平台必要設定與實機驗收

| 平台 | 正式部署前需要完成 | 必須實際驗證的結果 |
| --- | --- | --- |
| Google Cloud／Firestore | 先確認專案、既有 DB、Standard／Native mode 與位置；只有另獲授權才建立，建議 `asia-east1` 與 Cloud Run 同區。確認 Firestore API 已啟用 | 測試資料庫可用 server SDK 完成交易；手機 SDK 完全無直接權限；本次 Emulator 成功不代表雲端 DB 存在 |
| Google Cloud IAM／Secrets | Cloud Run 使用專用 service account，授予需要的 Firestore 資料操作及指定 Secret 讀取權限，保留現有 Vertex／Cloud TTS 權限；不使用 Owner 當執行身分 | 未授權身分不能讀寫；Apple 私鑰與 identity／LevelPlay secrets 不出現在建置輸出、HTTP 回應、App 或 log |
| Firestore TTL／索引 | 部署本目錄規則及 `firestore.indexes.json`，確認 PCM 不索引、音訊／session／challenge／proof／cost 欄位 TTL | 過期資料由 TTL 清除；即使 TTL 尚未執行，server clock 已拒絕過期 session、challenge 和音訊 |
| Cloud Run／成本及入口 | 維持既有台灣服務位置；測試與正式驗證配置分開；入口、請求大小、instance 數與費用告警適當限制 | 多 replicas 共用預算；停止會員或 AI 不影響基本鬧鐘；通知／廣告回呼只靠 Apple／平台簽章驗證，不信任 URL 內任意 member ID |
| 刪除維護工作 | 部署 `node membership/maintenance-cli.js` 為 IAM-only Cloud Run Job；只需兩庫 ADC 權限與 DB 設定，不需 Apple／廣告／AI／HMAC secrets。雙環境批次、失敗 exit code、Scheduler 與告警見 [MAINTENANCE.md](MAINTENANCE.md)，不提供公開清除 API | 模擬刪除中斷、服務重新啟動後，`pending` 標記能重試至 `complete`；另一庫故障不阻止成功庫；工作階段立即失效；仍清楚告知訂閱尚未取消 |
| App Store Connect 商品 | 提供 `com.shukaihu.RainyClock.plus.monthly` 與非消耗型 `com.shukaihu.RainyClock.banner.lifetime`；停止提供 `.plus.yearly` 新購，保留歷史交易相容。完成合約／稅務／銀行及審查資料 | 最新指定美國 US$1／月、買斷 US$10；台灣 NT$10／月、買斷 NT$100，其他商店待決定。ASC 實際設定見 staging；App 顯示 StoreKit 當地價格。家庭共享未啟用，後端拒絕未配置的 family-shared 交易 |
| App Store Server API／通知 | 配置 API key、issuer、Apple 根憑證、App 數字 ID；在 Connect 分別設定 Sandbox／Production Notifications V2 HTTPS URL `/v1/membership/apple/notifications` | 實測購買、待批准、取消、恢復、續訂、到期、退款、寬限期、延遲／重複通知及漏接後 API 對帳；不能只用自製 JWS fixture 宣稱正式簽章已通過 |
| iOS／App Attest | Bundle／Team ID、App Attest capability、entitlement 與後端環境一致；配合 App Store 已簽章資料驗證及裝置綁定 | 實機重新安裝、第二台裝置、App Store 帳號切換、舊 assertion／challenge 重放皆符合預期；Simulator mock 並非真 App Attest。iOS 17 相容性與缺失 appTransactionID 的處理須以真簽章測試確認 |
| LevelPlay | 後台 S2S callback 設為 `https://<測試或正式服務>/v1/membership/levelplay/callback?userId=[USER_ID]&rewards=[REWARDS]&eventId=[EVENT_ID]`；reward amount 固定 1，設定私鑰。手機 SDK 初始化使用伺服器核發 userId | 只使用官方 Test Suite／登記測試裝置，確認簽章回呼、延遲重送與重複事件只授予一次；UI 的「看完」事件不可自行加額度；不採未簽章的 dynamic/custom 參數認會員。不加入 AdMob |
| 移轉與隱私 | 核准舊 Keychain 額度的可信移轉／補償方式及固定 cutover；更新隱私政策與 App Store 隱私揭露；提供刪除會員及獨立管理訂閱入口 | 升級不清空舊免費／廣告次數，也不能重複領取；「恢復購買」不聲稱會同步設定或手機已保存音檔 |

以上為正式開放前配置及驗收項目；已完成的 Sandbox 資源以 staging 紀錄為準。
不代表已建立商品、啟用廣告正式流量或完成平台認證。本機與 Emulator 只驗證程式契約
及交易一致性；平台真實測試與正式啟用分開處理。

## 本機測試

純領域測試無網路、無帳號、無付費呼叫：

```sh
cd weather-proxy
npm ci
node --test test/membership-domain.test.js
```

上述命令會清楚標示 Firestore integration skipped。要跑真正的 Firestore 交易，使用
Java 21 與 Firebase Emulator（只綁定 localhost，不連正式資料庫）：

```sh
cd weather-proxy
npx firebase-tools emulators:start --only firestore --project rainyclock-membership-emulator
```

在另一個 terminal：

```sh
cd weather-proxy
FIRESTORE_EMULATOR_HOST=127.0.0.1:8686 node --test test/membership-domain.test.js
```

包含既有語音／天氣與所有會員、安全、HTTP、成本測試的完整驗證：

```sh
FIRESTORE_EMULATOR_HOST=127.0.0.1:8686 npm test
```

先前續訂實作批次結果：**142 項通過、0 失敗、0 跳過**，包含免費初始一次、跨裝置並行、
既有 ledger 保留、訂閱商品／續訂偏好、舊通知與缺少 renewal 的合併、到期／退款，
以及真 Firestore Emulator 並行續訂更新／交易測試；紀錄為
`/tmp/rainyclock-renewal-backend-all.log`。Apple／App Attest
驗證測試包含簽章 fixture／替身與拒絕路徑，這個數字不代表真 Sandbox 或正式連線
已驗收，也不包含正式廣告流量。
後續 Sandbox 部署批次的完整 151 項及入口 18 項測試均通過；原始紀錄與雲端驗證
見 [測試環境紀錄](../../docs/MEMBERSHIP-STAGING.md)，本次接入金鑰未修改程式或重跑測試。

測試使用隨機 namespace，結束後只刪除自己的測試資料。不可移除 emulator guard
而拿正式帳戶執行測試。啟用完整 runtime 的模擬器配置則另要求 `demo-` project ID；
此領域測試使用獨立、只會在指定 emulator 時建立的 fixture project。

2026-09-16 已使用官方 Firestore Emulator **1.22.0**、Temurin JRE 21 實際驗證
並行預留、PCM 持久保存／重新取回、廣告去重、失敗退回、退款通知與刪除。
不依賴 Firebase CLI 的同等啟動方法是 Java 執行官方 emulator JAR，傳入
`--host 127.0.0.1 --port 8686 --project_id rainyclock-membership-emulator --rules firestore.rules --database-edition standard`。

官方依據：[交易與重試](https://docs.cloud.google.com/firestore/native/docs/manage-data/transactions)、
[TTL 限制](https://docs.cloud.google.com/firestore/native/docs/ttl)、
[官方 emulator 版本與 checksum](https://github.com/firebase/firebase-tools/blob/master/src/emulator/downloadableEmulatorInfo.json)。

## English

This domain is deployed to an isolated, enabled Sandbox, not production billing. Firestore transactions serialize
member usage and atomically persist successful PCM with debit. Stable idempotency keys never
repeat synthesis; failed attempts restore their original funding, and abandoned leases become
terminal after five minutes. Result downloads remain free for the 24-hour retry window. Timezone
changes cannot shorten an existing window and activate at most once per 24 hours; DST still follows
local midnight. Legacy device-only credits remain quarantined pending an approved migration;
do not discard them or trust client counts. Deletion revokes access before asynchronous erasure,
retains disclosed minimal pseudonymous abuse-prevention evidence, and does not cancel an Apple
subscription. The Sandbox IAP key and notification URL are configured. After propagation, Apple's
TEST notification was delivered successfully and the real Sandbox payload was verified using the
official verifier and online certificate checks. Cloud Run confirms the matching POST returned 200;
TEST notification integration passed. Earlier 4040007 errors are resolved. TEST does not
prove a purchase or create purchase/quota ledger entries.
The user's latest September 21 confirmation and screenshot establish that both Taiwan and US
Sandbox testers are created (two visible rows); the inconsistent heading count does not override
that evidence. Credentials remain with the user. Device login and purchases are still unverified.
The subsequent September 21 entitlement decision makes both monthly and lifetime include banner
removal, calendar and one shared daily AI generation. Lifetime is permanent current-feature access
and takes display priority. Block redundant monthly purchase while it is active; retain real Apple
subscription details and management without silently cancelling. Subscription expiry cannot remove
calendar if lifetime is still valid. Free initial one and extra-generation rewards are unchanged.
Future disaster-closure lifetime eligibility is not decided. This code change does not itself prove
production deployment. Sandbox revision 00004-kkd includes the minimal calendar entitlement change,
and ASC lifetime English/Traditional Chinese copy is saved and read back; see staging for evidence.
The latest September 21 catalog offers monthly and non-consumable lifetime only: US$1/month and
US$10 once in the US, NT$10/month and NT$100 once in Taiwan. Annual is no longer offered; existing
verified annual transactions retain status compatibility. Taiwan prices are independently specified.
September 21 ASC prices are saved and verified: monthly/lifetime have US and Taiwan availability
only (2 territories), annual is off sale (0 territories), future-territory expansion is off. The
lifetime US base change recalculated Apple-managed equivalents, then Taiwan was manually fixed
at NT$100. Other unavailable territories' generated prices are not approved prices. September 16
prices are historical; see staging for evidence. No products are submitted or released;
review screenshots are missing and family sharing is off. Real-device login, products, purchases,
device/App Attest, LevelPlay and
AI end-to-end tests remain pending; AI is disabled. Production deployment, TTL/index/IAM configuration,
products, privacy and LevelPlay credentials remain separate release work. See the staging record for
current cloud resources and HTTP verification results.
