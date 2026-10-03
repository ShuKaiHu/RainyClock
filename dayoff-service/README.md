# RainyClock 天災停班停課服務（獨立預覽）

Node.js 22 的共用後端，以 NCDR 正式會員 Atom/CAP 介面取得行政院人事行政總處公告，讓所有手機讀取同一份經驗證的快取。它由兩個 Cloud Run 工作組成、共用一個 Firestore 資料庫：`src/job.js` 是 Cloud Scheduler 每 30 分鐘觸發一次的 Cloud Run Job，負責抓取、驗證、寫入 Firestore 並推播；`src/server.js` 是只回應請求的 Cloud Run service，從 Job 寫好的文件回覆手機，本身沒有輪詢、沒有金鑰、沒有磁碟。**2026-09-24 起已部署在 Cloud Run：來源是免金鑰的 `open-data`（沒有 NCDR 會員金鑰），APNs 金鑰放在 Secret Manager；資源與驗證紀錄見 `DEPLOYMENT.md`。** NCDR 會員來源的正式憑證連線仍未驗證。

服務不直接判斷某位使用者是否放假。手機依公告原文、公告發送日、鬧鐘日期、鄉鎮市區與停班／停課設定判斷；原文不明確便維持鬧鐘。住家、工作地址、路線及行政區不會傳給此服務。

## 資料來源

- 正式介面：`https://alerts.ncdr.nat.gov.tw/webapi/RssAtomFeed.ashx?AlertType=33&apikey=<API_KEY>`。
- [NCDR 2026/1/30 介接方式公告](https://alerts.ncdr.nat.gov.tw/web/home/news/1000027)與[API 會員申請說明](https://alerts.ncdr.nat.gov.tw/web/developer/alerts-api)。會員註冊「僅受理公務、公司或學校信箱」，個人信箱不予通過（2026-09-24 讀回註冊頁）。
- 因此 `NCDR_SOURCE` 二選一：`member` 用會員介面；`open-data` 用 data.gov.tw [資料集 20457](https://data.gov.tw/dataset/20457) 登錄的免金鑰網址（政府資料開放授權）。NCDR 公告舊版介接「預計 3 月 31 日下架」，但 2026-09-24 實測仍回 200。兩者不互為備援：抓不到就 503，鬧鐘照響，告警會響。
- [NCDR FAQ](https://alerts.ncdr.nat.gov.tw/web/platform/faq)說明 Feed 是「最新一則 CAP 起回溯七天」，並非「現在起回溯七天」。因此 9 月抓到 8 月公告屬可能情況，抓取成功不能代表今天停班。未配置 Key 時不會抓取任何來源。
- [DGPA 官方查閱頁](https://www.dgpa.gov.tw/typh/daily/nds.html)供使用者核對，服務不抓其 HTML。公告可能前晚、清晨或隨時更新，每天僅查一次不足。
- [政府開放資料集 20457](https://data.gov.tw/dataset/20457)提供 DGPA 停班停課 CAP 來源與政府資料開放授權；該目錄仍列舊來源，正式連線應以前述 NCDR 新介接公告為準。

`test/fixtures/afternoon.cap` 保留 2026/8/22 高雄市桃源區真實 CAP 的主要欄位，instruction 縮短。來源為 `https://alerts.ncdr.nat.gov.tw/Capstorage/DGPA/2026/workschoolclose_cap/dgpa.gov.tw_workSchlClos_20260822141104_i_6403700_001.cap`。測試以本機 fixture 執行，不會對官方網站做大量請求。

## 本機執行

```sh
cd dayoff-service
npm ci
npm test
cp .env.example .env
# 在自己的編輯器填入 NCDR_API_KEY；不要提交、貼到對話或記錄它。
npm run local
```

需要 Node.js 22。`npm run local` 執行 `src/local.js`：把 Job 的輪詢、推播與 service 的讀取端放在同一個常駐程序，狀態預設放在記憶體、只聽 `127.0.0.1:8080`，關掉就沒了；它只給筆電用，不會被部署。不填 key 仍能啟動檢查設定狀態：`GET /health` 會回 503 與 `state: "not_configured"`；`GET /v1/suspensions` 同樣回 503，絕不回假的空公告。APNs 四個設定全部留白即可使用手機主動同步／背景更新模式。部分填寫 APNs 設定會明確啟動失敗，避免誤以為推播已啟用。

要用真正的 Firestore 交易（需 Java 21），先啟動 emulator，再以 `demo-` 開頭的專案名執行；`src/runtime.js` 在 `FIRESTORE_EMULATOR_HOST` 設定時拒絕其他專案名，所以本機永遠碰不到正式資料庫：

```sh
npx firebase-tools emulators:start --only firestore --project demo-rc-dayoff
# 另一個 terminal
FIRESTORE_EMULATOR_HOST=127.0.0.1:8686 GOOGLE_CLOUD_PROJECT=demo-rc-dayoff DAYOFF_FIRESTORE_DATABASE=dayoff-emulator npm run local
FIRESTORE_EMULATOR_HOST=127.0.0.1:8686 npm test   # 連同 emulator 測試一起跑；未設定時該部分跳過
```

`firebase.json` 把 emulator 綁在 `127.0.0.1:8686`，與 weather-proxy 相同，兩邊可以共用同一個 emulator（single-project 警告無害）。要單獨跑 Job 一次，用 `npm run job`（需要 `NCDR_API_KEY` 與 Firestore 設定；本機同樣只能指向 emulator）。

### 環境變數

兩個部署入口讀取的設定不同；記憶體 store 不能由環境變數選用，只有 `src/local.js` 在沒有 `FIRESTORE_EMULATOR_HOST` 時使用它。`.env.example` 列出全部名稱，留白即採預設值。

Firestore（Job 與 service 共用）：

| 環境變數 | 預設／用途 |
|---|---|
| `GOOGLE_CLOUD_PROJECT` | 專案 id；設定 `FIRESTORE_EMULATOR_HOST` 時必須以 `demo-` 開頭 |
| `DAYOFF_FIRESTORE_DATABASE` | 必填的具名資料庫，正式為 `dayoff-production`；不接受 `(default)`，也不得與會員資料庫共用 |
| `DAYOFF_NAMESPACE` | `dayoff_production_v1`；所有文件路徑前綴 `dayoffNamespaces/<namespace>/` |
| `FIRESTORE_EMULATOR_HOST` | 只在本機設定，例如 `127.0.0.1:8686` |

請求服務 `src/server.js`（Cloud Run service `rainyclock-dayoff`）：

| 環境變數 | 預設／用途 |
|---|---|
| `PORT` / `HOST` | `8080` / `0.0.0.0`；Cloud Run 會自行注入 `PORT` |
| `MAX_CACHE_AGE_MS` | 預設 `900000`（15 分鐘，允許 60000–86400000）；`checkedAt` 超過這個時間就回 503 `stale_cache`。正式與 sandbox 部署都明確設為 `3600000`：快照超過 1 小時（連續漏兩次輪詢）才算過期 |
| `SNAPSHOT_CACHE_MS` | `5000`，每個 instance 每 5 秒最多讀一次 `state/current`，吸收推播後擴充功能的同時讀取 |
| `PUSH_CONFIGURED` | `1` 表示 Job 有 APNs 憑證：`/health` 的 `pushConfigured` 與 `POST /v1/devices` 的 503 `push_not_configured` 都由它決定，service 本身不持有金鑰 |
| `APNS_PUSH_MODE` | `alert`（預設）或 `background`，只在 `PUSH_CONFIGURED=1` 時回報，須與 Job 一致 |
| `TRUST_PROXY` | `1` 時限速以 `X-Forwarded-For` **最後一個**位址為準（Cloud Run 把它看到的來源接在客戶端自填的值後面，前面的都是客戶端可以偽造的），否則用 socket 位址 |

輪詢 Job `src/job.js`（Cloud Run Job `rainyclock-dayoff-poll`）：

| 環境變數 | 預設／用途 |
|---|---|
| `NCDR_SOURCE` | `member`（預設，需 `NCDR_API_KEY`）、`open-data`（免金鑰，用 data.gov.tw 資料集 20457 登錄的 `RssAtomFeed.ashx?AlertType=33`）或 `fixture`（不連 NCDR，把同一 namespace 的 `fixture/current` 文件當成已解析的 Feed；只允許名稱含 `sandbox` 的 `DAYOFF_NAMESPACE`，否則啟動即 `fixture_not_allowed`，見下方「Sandbox 測試堆疊」）。明確設定，不是備援；摘要、`state/current.source` 與 `/health/details` 都會標示 |
| `NCDR_API_KEY` | `member` 來源的 NCDR 會員金鑰，由 Secret Manager 注入，只在 Job；`open-data` 與 `fixture` 時必須留白 |
| `POLL_INTERVAL_MS` | 預設 `300000`（允許 60000–3600000）；正式部署明確設為 `1800000`，與 Scheduler 的 30 分鐘節奏一致。在 Job 裡它只決定成功後寫進 `state/current`、由 `/health` 回報的 `nextAttemptAt`，不會擋下一次執行（何時執行由 Scheduler 決定，只有失敗後的退避會擋）；`src/local.js` 的常駐程序才真的以它為輪詢間隔 |
| `REQUEST_TIMEOUT_MS` | `10000`，包括回應串流的每次請求期限；整輪最長 60 秒 |
| `BROADCAST_CONCURRENCY` | `16`（1–64）個並行 APNs 請求 |
| `BROADCAST_PAGE_SIZE` | `200`（50–500）台裝置一頁，每頁送完才寫入游標 |
| `LEASE_MS` / `LEASE_RENEW_MS` | `120000` / `30000`；輪詢與推播的租約長度與心跳間隔，心跳須短於租約 |
| `RUN_BUDGET_MS` | `420000`，須小於 task timeout；超過時推播在下一頁停下並留到重試 |
| `DAYOFF_SERVICE_URL` | 選填的 service https 網址（不含路徑）；revision 改變時先 GET 一次暖機 |
| `APNS_TEAM_ID` / `APNS_KEY_ID` | 選用的 Apple APNs 憑證識別碼 |
| `APNS_PRIVATE_KEY_PATH` | 獨立 APNs `.p8` secret 掛載路徑，不可挪用 WeatherKit key |
| `APNS_TOPIC` | 與 iOS App 相同的 bundle identifier |
| `APNS_PRODUCTION` | 有 APNs 設定時必填：`false` 用 sandbox（Xcode Debug），`true` 給 TestFlight／App Store |
| `APNS_PUSH_MODE` | `alert`（預設）：對所有裝置送同一則可見推播，由手機的通知擴充功能比對本機行政區後改寫；`background`：舊的靜默同步提示 |
| `CLOUD_RUN_EXECUTION` | Cloud Run 注入的 execution 名稱，作為租約擁有者；只在測試覆寫 |

`src/local.js` 讀取 Job 的 `NCDR_API_KEY`（可留白）、`POLL_INTERVAL_MS`、`REQUEST_TIMEOUT_MS` 與 APNs 設定，service 的 `PORT`、`MAX_CACHE_AGE_MS`、`SNAPSHOT_CACHE_MS`，以及 `BROADCAST_CONCURRENCY`（本機預設 4）。本機模式另外要求 `MAX_CACHE_AGE_MS` 不小於 `POLL_INTERVAL_MS`，否則啟動即 `invalid_configuration`；要在本機重現正式節奏，兩個都要設（`1800000` 與 `3600000`）。`NCDR_SOURCE=fixture` 在本機也受 namespace 限制：設了 `FIRESTORE_EMULATOR_HOST` 時用 `DAYOFF_NAMESPACE`（預設是正式名稱，所以要設成含 `sandbox` 的名稱），記憶體模式預設 `local_sandbox`。

## HTTP 契約

`GET /v1/suspensions`：成功回 200，`Content-Type: application/json`、`Cache-Control: no-store`。GET 絕不觸發上游查詢。

```json
{
  "schemaVersion": 1,
  "checkedAt": "2026-09-15T12:30:00.000Z",
  "sourceUpdatedAt": "2026-08-24T10:29:00.000Z",
  "revision": "sha256-of-normalized-notices",
  "notices": [
    {
      "id": "dgpa.gov.tw_workSchlClos_20260822141104_i_6403700_001",
      "sentAt": "2026-08-22T06:11:04.000Z",
      "description": "[停班停課通知]高雄市桃源區:今天下午已達停止上班及上課標準。行政院人事行政總處。如有任何問題請撥1999(市內直撥)。",
      "severity": "Extreme",
      "msgType": "Alert",
      "status": "Actual",
      "geocodes": ["6403700"],
      "references": []
    }
  ]
}
```

- `checkedAt` 是本服務完成本輪抓取與驗證的時間；不會把舊公告改成今天。
- `sourceUpdatedAt` 保留 Feed 原有更新時間；合法空 Feed 缺少此欄時為 `null`。
- `sentAt` 為 CAP `sent`，全部時間正規化為有時區的 ISO8601 UTC。
- `description` 保留 CAP 原文，不依鄉鎮名稱猜測、補寫日期或擴張範圍。CAP 的 `effective/expires` 只驗證格式，不拿來當實際放假日。
- `geocodes` 只取 `Taiwan_Geocode_103` 的字串；保留縣市、鄉鎮市區及更細碼，不做錯誤截斷。
- `references` 是 CAP 參照舊公告的 identifier 陣列，用於更新／撤銷關係。`Cancel` 可沒有 `info`，此時文字與 geocodes 為空，不能拿來确认放假。
- `status` 仍保留 Test／Exercise 等狀態；手機只能採用 Actual。`severity` 不等於完整停班／停課判斷。
- 正常空 Feed 為 `notices: []`；來源出錯、部分 CAP 無法取得、XML 不合法或快取過期，回 **503** `{ "error": "安全的固定錯誤碼" }`，不提供看似成功的空結果。Job 抓取失敗時只改寫 `state/current` 的錯誤欄位、不動快照本身，service 讀到後立即以該錯誤碼回 503，直到下一次成功抓取（正式環境每 30 分鐘才輪詢一次，所以一次失敗的 503 通常約 30 分鐘；退避上限也是 30 分鐘，連續失敗第 7 次起或來源要求 30 分鐘以上的 `Retry-After` 時，下一次排程會以 `skipped:"backoff"` 跳過，503 可能再多 30–60 分鐘）；`checkedAt` 每次成功都會重寫，所以只有 Job 停止運作超過 `MAX_CACHE_AGE_MS`（正式為 1 小時）才會出現 `stale_cache`。Firestore 沒有文件（Job 從未成功執行）時為 `not_configured`，Firestore 本身讀不到時為 `storage_unavailable`。

`GET /health`：可用回 200，未配置或來源異常回 503。回應包括 `configured`、`available`、`state`、`errorCode`、`lastAttemptAt`、`lastSuccessAt`、`nextAttemptAt`、`pushConfigured` 及 `pushMode`（未配置推播時為 `null`）。健康狀態不表示每支手機已收到更新。

`GET /health/details`：給值班用的診斷，永遠 200（Firestore 讀不到時 503 `storage_unavailable`）。在 `/health` 欄位之外多回 `revision`、`checkedAt`、`noticeCount`、`ageMs`、`sourceUpdatedAt`、`job`（最後一次 Job 執行的 `owner`、`finishedAt`、`durationMs`、`code`、`changed`）、`lease`（輪詢租約的 `owner`、`leaseUntil`）、`broadcast`（待送或最近一個 revision 的推播 claim：`state`、`attempts`、`accepted`、`failed`、`unregistered`、`retryPending`、`finishedAt`）、`storage` 與 `serverTime`。每次都直接讀 Firestore、不經快取，內容不含任何 token 或 installationId。iOS 不讀這兩個介面；`/health` 的九個欄位是固定契約，新欄位只加在 `/health/details`。判讀方式（正式環境每 30 分鐘輪詢一次）：`state: "ready"`、`ageMs` 小於 35 分鐘、`job.finishedAt` 在 35 分鐘內、`broadcast` 為 `null` 或 `state: "done"` 即正常；`ageMs` 介於 35 分鐘與 1 小時之間代表漏了一次輪詢，滿 1 小時就是 `stale_cache`。

### 選用的裝置註冊

只在 App 使用者開啟功能後向 APNs 註冊並呼叫這個介面。裝置自行以密碼安全亂數建立 32-byte credential，hex 編碼為 **64 字元**，保存在 Keychain。所有正式流量必須使用 HTTPS；credential 不得放 URL。

`POST /v1/devices`，`Content-Type: application/json`：

```json
{
  "installationId": "310251b2-9c20-4dcb-b695-89b78bb1f148",
  "deviceToken": "<64-character hex APNs token>",
  "credential": "<64-character random hex credential>"
}
```

首次成功 201，更新成功 200，回 `{ "registered": true }`；同一 installationId 的更新或刪除必須匹配原 credential，否則 403。伺服器只保存其 SHA256，不保存原文。`DELETE /v1/devices` 使用同樣 JSON，但不需 deviceToken，成功 204；即使 APNs 暫停配置仍可刪除。APNs 未配置時 POST 回 503 `push_not_configured`。

限制：JSON 上限 1 KiB、最多 10,000 個有效 installation（在建立交易之外計算 90 天內更新過的文件——交易內的聚合計數會讓同時建立的註冊互相衝突、重跑到 503——所以同時大量建立時可能少量超過）、90 天未更新即視為不存在並由 Firestore TTL 清除；App 每次啟用／前景應更新註冊。寫入每個用戶端每分鐘 30 次，限速表放在各 instance 的記憶體、上限 10,000 筆（滿了就整表清空重數，不拒絕新手機）：`TRUST_PROXY=1` 時以 `X-Forwarded-For` 最後一個位址（Cloud Run 接在客戶端自填值後面的真正來源）為鍵，否則用 socket 位址；Cloud Run 最多 3 個 instance，所以實際上限約每分鐘 90 次，這是防濫用的緩衝而非安全機制。每個 instance 同時進行中的寫入（含建立前的讀取與計數）上限 128 筆，滿載回 503 `device_registry_busy`，可稍後重試。目前不是付費權益驗證或 App Attest 方案。

每當公告內容 revision 改變，Job 在同一筆 Firestore 交易裡寫入新快照與 `broadcasts/<revision>` 的推播 claim，再由同一次執行以 `BROADCAST_CONCURRENCY`（預設 16）個並行請求通知所有註冊裝置同步。Job 每 30 分鐘才執行一次，所以公告出現在來源之後，推播最晚約 30 分鐘才送出。只變動 checkedAt 不會每 30 分鐘推一次；重啟或重複執行時以 Firestore 裡的 revision 字串比對，相同就不推。較新的 revision 會取代尚未送完的舊批次（舊的在下一頁停下，claim 標為 `superseded`）；失效 token 依 APNs 410 的時間戳做條件刪除，較新的重新註冊會保留；重複 token 每次只送一次。

推播 claim 是可續傳的：每送完一頁才寫入游標，Job 因預算、SIGTERM 或當機中斷時，下一次執行從游標繼續（最多重送一頁，手機端由 `apns-collapse-id` 去重）；APNs 回 429／5xx／逾時的 token 記在 `broadcasts/<revision>/retries/` 下，同一 revision 的下一次執行只補送這些；同一 revision 最多嘗試 3 次，用盡時把 claim 標為 `exhausted`、清掉 `pendingBroadcastRevision`，只告警一次（之後的 tick 不再認領，claim 被 TTL 清掉後也不會重送整輪）；還有可重送 token 的執行以 exit 0 結束，補送要等下一個 tick，正式節奏下每次相隔 30 分鐘；一輪裡可重試的失敗超過一半（至少 100 筆之後）會由斷路器停下。APNs 憑證被拒（403 `InvalidProviderToken` 等）時立即中止並以 exit 1 告警；那一次不計入嘗試次數，換鑰後的執行從游標續傳。這仍只是更新提示：新裝置在 revision 未變時註冊不會因為同一 revision 收到補送，APNs 拒絕的其他錯誤不重送，發送結果只留下匿名計數。手機註冊完成後須立即 GET 同步，並在前景／背景執行機會時再次同步；iOS 背景執行仍無法保證。

`alert` 模式（預設，2026-09-23 決定）的 payload 為 `aps.alert` 的 `title-loc-key: dayoff_push_title`／`body-loc-key: dayoff_push_body`、`sound: default`、`mutable-content: 1`、`thread-id: dayoff`，加上 `type: "dayoff-sync"` 與 `revision`；使用 `apns-push-type: alert`、優先序 10、`apns-collapse-id: dayoff-sync`（每台裝置永遠只有一則，新版本取代舊的）、10 小時後過期。**伺服器對所有裝置送完全相同的內容，payload 裡沒有任何縣市或行政區**；手機上的 Notification Service Extension 在 App 未執行時也會被系統喚醒，讀取 App 存在 App Group 的住家／目的地行政區、自行 GET `/v1/suspensions`，再把通知改寫成「符合、相關但不略過、無關（靜音）」三種之一。擴充功能失敗或逾時，系統就照 loc-key 顯示 App 本地化的通用文字。

`background` 模式的 payload 只有 `aps.content-available: 1`、`type: "dayoff-sync"` 與 `revision`，`apns-push-type: background`、優先序 5、1 小時過期。

兩種模式都只是提示：**APNs 接受不等於送達，送達也不等於鬧鐘已取消**。iOS 仍須同步最新公告、重新判斷並完成本機 AlarmKit 操作。通知未送達、App 被強制關閉或無可用背景執行機會時，既有鬧鐘維持。

### 手機處理完成回報

手機取得公告、完成該版本的本機處理後，才呼叫 `POST /v1/devices/sync-receipt`。這是已註冊 installation 的認證介面；不得以伺服器發送推播或 APNs 接受代替手機回報。

```json
{
  "installationId": "310251b2-9c20-4dcb-b695-89b78bb1f148",
  "credential": "<64-character random hex credential>",
  "revision": "<64-character hex revision from the fetched feed>",
  "checkedAt": "2026-09-15T12:30:00.000Z",
  "appliedAt": "2026-09-15T12:30:02.000Z",
  "result": "applied"
}
```

`checkedAt` 必須取自該次取得的 Feed，`appliedAt` 是手機完成處理的時間。`result: "applied"` 表示手機已完成該份公告的判斷和必要的排程操作，**不表示所有鬧鐘都被取消**；保留原鬧鐘也可能是正確結果。若手機當下沒有啟用鬧鐘，回 `"no_alarm"`。伺服器不接收住家／目的地、鬧鐘時間、略過日期或停班判斷明細，也不以這份回報遠端操作鬧鐘。

成功回 200 `{ "recorded": true }`。只保留每台裝置最新一筆回報，以 `checkedAt` 優先、`appliedAt` 次之排序；相同或較舊的回報回 200 `{ "recorded": false }`，手機可丟棄這筆待送資料。不同時區先正規化為 UTC 再比較。`checkedAt` 與 `appliedAt` 都不能超過伺服器現在時間 5 分鐘，`checkedAt` 也不能比 `appliedAt` 晚超過 5 分鐘；這個容許範圍用於手機和伺服器的小幅時鐘差異。回報不要求 `checkedAt` 等於伺服器目前輪詢時間，同一 revision 可跨多次輪詢。

`POST /v1/devices/sync-status` 使用 `{ "installationId": "…", "credential": "…" }` 認證 JSON，回 200：

```json
{
  "status": "applied",
  "matchesCurrentRevision": true,
  "currentRevision": "<64-character hex revision>",
  "receipt": {
    "revision": "<64-character hex revision>",
    "checkedAt": "2026-09-15T12:30:00.000Z",
    "appliedAt": "2026-09-15T12:30:02.000Z",
    "result": "applied"
  }
}
```

狀態規則：

- `applied`／`no_alarm`：有可用來源、回報符合目前 revision，且 `appliedAt` 在台灣當日。只是該時間點完成處理的歷史回報，不是手機持續在線、推播一定送達或鬧鐘狀態永遠不變的證明。
- `pending`：尚無回報、來源 revision 已改變，或台灣日期已跨日。跨日即使 revision 相同，也需要手機重新處理日期相關規則；`matchesCurrentRevision` 此時仍可能為 `true`。
- `source_unavailable`：官方來源未配置、驗證失敗或過期；`currentRevision: null`、`matchesCurrentRevision: false`。來源不可用時仍能查詢歷史回報，HTTP 保持 200。

`receipt` 尚不存在時為 `null`；跨日或來源變更時仍保留其原時間，不把舊回報改成新成功。查詢只讀共用快取，不觸發官方來源請求。

兩個新介面均使用 JSON、1 KiB 上限及現有每分鐘 30 次的共用限速。未註冊或已過期回 404 `device_not_registered`，credential 不符回 403 `device_credential_mismatch`，格式不合法回 400 `invalid_device_request`，超大回 413 `device_request_too_large`。APNs 暫停配置時，已註冊裝置仍可回報／查詢。回報與雜湊 credential、裝置 token 一起保存在 Firestore 的 `devices/<installationId>`；重新註冊或 token 輪替保留最新回報，刪除、90 天過期或有效的 APNs 410 清除時一併移除。回報本身沒有另外的自動重送排程。

## 快取、期限與部署方式

沒有常駐程序，也沒有磁碟。狀態全部在 Firestore：專案 `rainyclock`、具名資料庫 `dayoff-production`（Standard、Native、`asia-east1`、開啟刪除保護、`firestore.rules` 全部拒絕），文件路徑前綴 `dayoffNamespaces/<DAYOFF_NAMESPACE>/`。不得重用任何會員資料庫，也不得用 `(default)`。

- `state/current`：唯一一份手機看得到的狀態。`noticesJSON` 保存 Job 雜湊時的那一串 `JSON.stringify(notices)` 原文（上限 900,000 bytes，超過即 `stored_state_too_large`），`revision` 是它的 sha256，只在 Job 從剛解析的 CAP 算一次、以字串比對、絕不從 Firestore 讀回的 map 重算。`checkedAt` 每次成功都重寫。抓取失敗時只改 `errorCode`、`failures`、`lastAttemptAt`、`nextAttemptAt`，快照欄位不動；HTTP 429 的 Retry-After（上限 1 小時）與 30 秒起指數退避至 30 分鐘的等待都存在這裡，下一次 Job 執行在任何網路請求前先看它，時間未到就以 `skipped: "backoff"` 結束。
- `state/lease`：輪詢租約（`LEASE_MS`，心跳續約），兩次執行重疊時後者以 `skipped: "lease_held"` 結束；同一 execution 的 task 重試可接管自己的租約。寫入 `state/current` 的交易會先確認租約仍在自己手上，較慢的舊執行不能覆蓋較新的結果。
- `caps/<capId>`：CAP 原始 XML（每則 ≤ 256 KiB，30 天 TTL），重用前一律重新通過 `parseCAP`，解析不了就當快取未命中重抓，不視為失敗。
- `fixture/current`：只有 sandbox namespace 才有的操作員文件（`{ notices: [...], sourceUpdatedAt }`），由 `src/fixture-cli.js` 寫入、`NCDR_SOURCE=fixture` 的 Job 讀取；沒有文件就是合法的空 Feed。正式 namespace 裡即使有這份文件也不會被讀。
- `devices/<installationId>`、`broadcasts/<revision>`、`broadcasts/<revision>/retries/<token>`：註冊與回報、可續傳的推播 claim、待重送的 token；`expiresAt` 分別為 90 天、7 天、7 天 TTL。
- `firestore.indexes.json` 記錄 `state.noticesJSON` 與 `caps.xml` 的索引豁免（索引字串上限 1500 bytes）和四個 `expiresAt` TTL 政策；沒有複合索引。`firebase.json` 指向 `dayoff-production`。

來源只允許固定官方 Feed，以及 `alerts.ncdr.nat.gov.tw/Capstorage/DGPA/<year>/workschoolclose_cap/*.cap` 的 HTTPS 路徑；禁止重新導向、其他主機、URL 金鑰傳播、DOCTYPE／ENTITY、過深 XML、超量項目與過大串流。每次請求預設 10 秒、整輪最長 60 秒、CAP 最多 4 個並行下載，與原本相同。

**Job `rainyclock-dayoff-poll`**（`node src/job.js`，Cloud Scheduler `5,35 * * * *` Asia/Taipei 觸發，即每 30 分鐘一次、避開整點，1 task、`--task-timeout 600s`、`--max-retries 1`）：驗證設定 → 取租約 → 讀 `state/current` 的退避 → 抓取驗證 → 一筆交易寫入快照（revision 改變時同時建立 claim 並把 `pendingBroadcastRevision` 指向它）→ 有 `DAYOFF_SERVICE_URL` 且內容改變時先 GET 一次暖機 → 續傳待送的 claim → `finally` 釋放租約、關閉 APNs HTTP/2 連線與 Firestore client → stdout 只印一行 `{"event":"dayoff_job", "severity", "ok", "skipped", "refreshed", "changed", "revision", "noticeCount", "errorCode", "warmup", "broadcast", "durationMs"}`，永遠不含金鑰、token、installationId 或原始錯誤文字 → 明確 `process.exit`。退出碼：租約被占、退避中、來源失敗（退避就是它的重試）、推播 `done`、已跑完裝置但還有可重送的 token、嘗試次數用盡（`ok:false`，由 log 指標告警）都是 0；設定錯誤、Firestore 不可用、租約遺失、APNs 憑證被拒、推播未跑完（預算／斷路器／SIGTERM）是 1，Cloud Run 的 task 重試從游標續傳。只有 Job 拿得到 `NCDR_API_KEY`（Secret Manager 環境變數）與 `.p8`（Secret Manager 掛載到 `APNS_PRIVATE_KEY_PATH`）。

**Service `rainyclock-dayoff`**（`node src/server.js`，`--cpu 1 --memory 512Mi --concurrency 80 --timeout 30 --min-instances 0 --max-instances 3`）：每個 instance 每 `SNAPSHOT_CACHE_MS` 最多讀一次 `state/current`，但每個請求都以當下時間重新判斷可用性，快取不會把 503 變成過期的 200。沒有任何 secret，`PUSH_CONFIGURED`／`APNS_PUSH_MODE` 只是宣告 Job 的設定。`min-instances 1`（約 US$5–8／月）是文件化的付費升級選項，只在真正警報期間 p95 延遲超過 3 秒時才考慮。收到 SIGTERM 時停止接受新連線、等進行中的請求最多 8 秒後結束。

兩個工作使用同一個不可變的映像 digest（`Dockerfile`：Node 22 alpine、不以 root 執行、只複製 `src/` 與 `apns.js`；`.gcloudignore` 排除 `test/`、`.env*` 與任何 `.p8`）。Service 與 Job 各用自己的 service account，只在 `dayoff-production` 上有條件式的 `roles/datastore.user`；Scheduler 的 service account 只有該 Job 的 `roles/run.invoker`。成本以免費額度為目標，而且取決於 Job 的執行次數而不是執行時間：Cloud Run Job 每次執行至少計費 1 分鐘（實際只跑十幾秒也一樣），整個帳單帳戶共用的免費額度是每月 240,000 vCPU-seconds，約 4,000 次單 vCPU 執行（每天約 129 次）。每 30 分鐘一次是每天 48 次，加上會員刪除 Job 每天 2 次，31 天約 93,000 vCPU-seconds，在免費額度內，Cloud Run Job 為 US$0；原本兩個排程各每 5 分鐘一次（每天共 576 次）整月約 US$15，這是 2026-10-02 改成 30 分鐘的原因。具名 Firestore 資料庫沒有免費額度，每月約 US$0.10。上線前必須先建立通知管道與告警：`dayoff_job` 摘要事件 2 小時沒出現（連續漏四次輪詢；Scheduler 死掉不會產生失敗的 execution）、execution 失敗、2 小時內三次以上 `ok:false` 或推播未完成。`MAX_CACHE_AGE_MS`、`POLL_INTERVAL_MS`、這些告警的時間窗，以及 iOS App 的 `DisasterMapStatus.maximumFeedAge`（1 小時）都跟著 Scheduler 的節奏走，改節奏時要一起改。

實際部署指令、資源名稱、映像 digest 與驗證紀錄放在 `DEPLOYMENT.md`。

後續可申請 NCDR 官方 HTTPS 推送，以減少輪詢延遲（目前最長約 30 分鐘）並保留輪詢補漏；目前沒有啟用該端點、申請審核或對外發送任何資料。

## Sandbox 測試堆疊

正式 Job 只在 Feed 的 revision 改變時推播，而 NCDR 只在颱風期間才會改，所以平常沒有辦法在手機上走完
「推播 → 通知擴充功能改寫 → 鬧鐘判斷」這條路。Sandbox 堆疊就是為了隨時能製造一次真正的推播：

- **同一個映像 digest**、同一個 `dayoff-production` 資料庫，但 namespace 是 `dayoff_sandbox_v1`：
  service `rainyclock-dayoff-sandbox`、Job `rainyclock-dayoff-poll-sandbox`，`APNS_PRODUCTION=false`
  （Xcode Debug 裝置的 token 只存在於 APNs sandbox），**沒有 Scheduler**，每次輪詢都是人手動執行。
- Job 用 `NCDR_SOURCE=fixture`：`performRefresh` 不連 NCDR，改讀 `fixture/current` 文件，把裡面的
  `notices` 當成已解析的 Feed（沒有 CAP 下載、沒有 CAP 快取）。之後的 `revisionFor`、單筆交易寫入、
  changed 判定、`pendingBroadcastRevision`、失敗退避全部與真實來源走同一段程式，所以改一次 fixture
  就是一次真正的推播。每則 fixture notice 都以 parser 保證的形狀規則驗證（ISO `sentAt`、非空
  `description`、`\d{2,11}` 的 geocode、DGPA 的 id 格式、合法的 `msgType`／`status`／`severity`），
  不合就是 `invalid_fixture_notice`／`invalid_fixture_document` 的失敗輪詢，快照保留、退避照記。
- **絕不碰正式環境**：`src/job.js` 與 `src/service.js` 都在 `DAYOFF_NAMESPACE` 不含 `sandbox` 時拒絕
  `fixture` 來源（`fixture_not_allowed`），`src/fixture-cli.js` 也拒絕寫入這種 namespace；正式 Job 的
  `open-data` 來源根本不讀 `fixture/current`。兩個堆疊唯一共用的是資料庫、IAM 與 `.p8` secret。

操作員 CLI（`npm run fixture -- <command>`，或部署後用 `deploy/fixture.sh` 一次做完「寫入 ＋ 執行 Job」）：

```sh
# 環境變數與 Job 相同：GOOGLE_CLOUD_PROJECT、DAYOFF_FIRESTORE_DATABASE、DAYOFF_NAMESPACE（必須含 sandbox）
npm run fixture -- set --county 新北市 --district 板橋區            # 明天停止上班、停止上課（預設）
npm run fixture -- set --county 臺東縣 --when today --scope school  # 今天照常上班、停止上課
npm run fixture -- set --county 連江縣 --day-part morning           # 明天上午停止上班、停止上課
npm run fixture -- set --county 臺東縣 --district 蘭嶼鄉 --geocode 1001416
npm run fixture -- show                                             # 印出目前的文件
npm run fixture -- clear                                            # 刪除文件 = 空 Feed，也是一次 revision 改變
```

不必部署也能在筆電上看完整流程：對 emulator 用同一組環境（`GOOGLE_CLOUD_PROJECT=demo-…`、
`DAYOFF_NAMESPACE=dayoff_sandbox_local`）先 `npm run fixture -- set …`，再 `NCDR_SOURCE=fixture npm run local`。
指令必須放在第一個參數（`set --county …`，不是 `--county … set`），未知或缺值的選項一律回 `invalid_fixture_command`；
Firestore 失敗時 stderr 會多一行 `{"event":"storage_failure","grpcCode":N}`，7／16 是 ADC 或 IAM、5 是資料庫 id、14 才是服務中斷。

`set` 產生**一則** `Alert`／`Actual` 公告，措辭照 `docs/dayoff-fixtures.json` 裡真實 DGPA 的句型
（`[停班停課通知]<縣市><鄉鎮市區>:<今天|明天><上午>?<停止上班、停止上課|停止上班、照常上課|照常上班、停止上課>。行政院人事行政總處。`），
停班時 `severity` 為 `Extreme`、只停課為 `Severe`，`sentAt` 是現在，id 為
`dgpa.gov.tw_workSchlClos_<台北時間 yyyymmddHHMMSS>_i_<geocode>_001`。`--district` 省略即縣市層級；
給了就對照 `RainyClock/Resources/taiwan-districts.json` 確認存在。那張表只有名稱沒有代碼，所以
geocode 預設是縣市的 Taiwan_Geocode_103 五碼（CLI 內建 22 個），要精確的七碼鄉鎮代碼用 `--geocode`。
手機端是用公告原文的地區文字比對使用者的縣市／行政區，geocode 只要求格式正確（2、5 或 7 碼、沒有 `-`），
所以縣市碼配鄉鎮文字足以走完手機上每一條路徑。CLI 先驗證指令、名稱、namespace，再建立 Firestore client；
只印一行 JSON，失敗只印錯誤碼。

手機端不改任何 plist：每個 Debug build 都由 `AppEnvironment.dayOffServiceURL` 讀 `Info.plist` 的
`DayOffSandboxServiceURL`（Release 才讀 `DayOffServiceURL`），裝置 token 也自然是 APNs sandbox 的
（TestFlight／App Store build 走 production APNs，對 sandbox Job 而言是無效 token，不要混用）。
`deploy/sandbox.sh` 印出的網址要等於 `DayOffSandboxServiceURL`；不同時更新的是那個鍵。通知擴充功能用 App
註冊時寫進 `DayOffSharedState.serviceURL` 的同一個網址。以 Debug 裝到真機、註冊後執行一次 `deploy/fixture.sh set …`，Job 立即推播，通知擴充功能自己 GET `/v1/suspensions` 拿到這則
fixture 公告並改寫橫幅。沒有 Scheduler，所以最後一次執行 1 小時後 sandbox service 會回 503 `stale_cache`
（手機退回保守規則、鬧鐘照響）——這正是設計行為；要再看一次就再執行一次 Job。

## 驗證

`npm test` 使用 Node 內建測試器與記憶體 store（與 Firestore store 同一介面、同樣的讀後寫限制與序列化交易），不碰磁碟、不需雲端。涵蓋真实 CAP、空 Feed、舊公告日期、CAP 更新／撤銷、XML namespace／DTD／超量、來源 URL 白名單、超時、429、單一抓取、來源失敗 503、狀態恢復與損毀狀態不服務、裝置 credential／限速、APNs 簽章與推播回應，手機回報的認證、排序、重複、時鐘差異、持久保存、重新註冊／刪除、來源異常和台灣跨日狀態，以及 store 語意、快照讀取端的快取與可用性判斷、推播 claim 的續傳／重送／斷路器／取代／嘗試上限、Job 的租約／退避／退出碼／摘要，和 service 設定、`X-Forwarded-For` 限速鍵與 `/health/details`，以及 fixture 來源（`test/fixture.test.js`：非 sandbox namespace 拒絕、設定 → 推播 → 不重複 → 清除再推播、壞 fixture 的失敗分支、CLI 措辭與參數驗證、以壞環境啟動 CLI 只印錯誤碼）。測試注入本機 fetch／HTTP2 transport，不需真實外部憑證。設定 `FIRESTORE_EMULATOR_HOST` 時另外執行真 Firestore 交易的測試（`test/firestore.test.js`，含以子程序執行 fixture CLI 寫入 emulator、再以 fixture 模式跑完整 `runJob` 到推播完成），未設定時跳過。`npm run check` 對每個原始檔做語法檢查。

尚未驗證：正式 NCDR API Key 回應是否仍使用相同 CAP link 路徑（不同時會明確報來源錯誤，不會放寬白名單）、正式 APNs credentials、實際裝置在背景／低耗電／强制關閉狀態的行為，以及容器部署。這些是正式上線前的實際環境整合工作，不得把本機通過測試描述為已上線。
