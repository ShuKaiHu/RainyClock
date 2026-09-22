# RainyClock 天災停班停課服務（獨立預覽）

Node.js 22 的單一共用服務，以 NCDR 正式會員 Atom/CAP 介面取得行政院人事行政總處公告，讓所有手機讀取同一份經驗證的快取。**此目錄已可執行與測試，但沒有部署、沒有建立 NCDR 會員，也沒有取得／使用真實 API Key 或 APNs 金鑰。** 正式憑證連線與真機背景喚醒仍須驗證。

服務不直接判斷某位使用者是否放假。手機依公告原文、公告發送日、鬧鐘日期、鄉鎮市區與停班／停課設定判斷；原文不明確便維持鬧鐘。住家、工作地址、路線及行政區不會傳給此服務。

## 資料來源

- 正式介面：`https://alerts.ncdr.nat.gov.tw/webapi/RssAtomFeed.ashx?AlertType=33&apikey=<API_KEY>`。
- [NCDR 2026/1/30 介接方式公告](https://alerts.ncdr.nat.gov.tw/web/home/news/1000027)與[API 會員申請說明](https://alerts.ncdr.nat.gov.tw/web/developer/alerts-api)。停班停課資料應以正式會員介面取得，服務沒有 keyless fallback。
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
node --env-file=.env src/server.js
```

需要 Node.js 22。預設只聽 `127.0.0.1:8081`。不填 key 仍能啟動檢查設定狀態：`GET /health` 會回 503 與 `state: "not_configured"`；`GET /v1/suspensions` 同樣回 503，絕不回假的空公告。APNs 四個設定全部留白即可使用手機主動同步／背景更新模式。部分填寫 APNs 設定會明確啟動失敗，避免誤以為推播已啟用。

| 環境變數 | 預設／用途 |
|---|---|
| `NCDR_API_KEY` | NCDR 會員金鑰，只放伺服器端 |
| `PORT` / `HOST` | `8081` / `127.0.0.1` |
| `DATA_DIR` | `./data`；雲端部署必須掛持久 volume |
| `POLL_INTERVAL_MS` | `300000`，每 5 分鐘輪詢；最低 1 分鐘 |
| `MAX_CACHE_AGE_MS` | `900000`，最後驗證超過 15 分鐘時回 503 |
| `REQUEST_TIMEOUT_MS` | `10000`，包括回應串流的每次請求期限 |
| `APNS_TEAM_ID` / `APNS_KEY_ID` | 選用的 Apple APNs 憑證識別碼 |
| `APNS_PRIVATE_KEY_PATH` | 獨立 APNs `.p8` secret 檔路徑，不可挪用 WeatherKit key |
| `APNS_TOPIC` | 與 iOS App 相同的 bundle identifier |
| `APNS_PRODUCTION` | `false` 用 sandbox；TestFlight／App Store 設 `true` |

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
- 正常空 Feed 為 `notices: []`；來源出錯、部分 CAP 無法取得、XML 不合法或快取過期，回 **503** `{ "error": "安全的固定錯誤碼" }`，不提供看似成功的空結果。前次好資料仍留磁碟供診斷與重啟快取；重啟後需重新驗證 Feed 才開始提供資料。

`GET /health`：可用回 200，未配置或來源異常回 503。回應包括 `configured`、`available`、`state`、`errorCode`、`lastAttemptAt`、`lastSuccessAt`、`nextAttemptAt` 及 `pushConfigured`。健康狀態不表示每支手機已收到更新。

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

限制：JSON 上限 1 KiB、最多 10,000 個 installation、90 天未更新自動過期；App 每次啟用／前景應更新註冊。寫入按來源 socket IP 限制每分鐘 30 次，並將限速記錄控制在 10,000 筆記憶體內；檔案序列寫入佇列上限 128 筆，滿載回 503，可稍後重試。服務不信任任意 `X-Forwarded-For`。若前置 reverse proxy，應由閘道配置實際用戶 IP 的限速與註冊防濫用；目前不是付費權益驗證或 App Attest 方案。

每當公告內容 revision 改變，選用 APNs 會以最多 4 個並行請求通知所有註冊裝置同步。只變動 checkedAt 不會每 5 分鐘推一次。較新的 revision 會取代尚未送完的舊批次；失效 token 依 APNs 410 清除，重複 token 每批只送一次。

目前 APNs 為可選的更新提示，沒有持久化逐台投遞 outbox 或失敗重送：推播失敗、服務在送完前重啟、或新裝置在 revision 未變時註冊，都不會因為同一 revision 而自動補送。手機註冊完成後須立即 GET 同步，並在前景／背景執行機會時再次同步；發送失敗只留下匿名計數。需要進一步提高送出嘗試率時，可加逐裝置短效 outbox，但仍不能保證 iOS 背景執行。

推播 payload 只包含 `aps.content-available: 1`、`type: "dayoff-sync"` 與 `revision`。使用 `apns-push-type: background` 與優先序 5；**APNs 接受不等於送達，送達也不等於鬧鐘已取消**。iOS 仍須同步最新公告、重新判斷並完成本機 AlarmKit 操作。通知未送达、App 被強制關閉或無可用背景執行機會時，既有鬧鐘維持。

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

兩個新介面均使用 JSON、1 KiB 上限及現有每分鐘 30 次的共用限速。未註冊或已過期回 404 `device_not_registered`，credential 不符回 403 `device_credential_mismatch`，格式不合法回 400 `invalid_device_request`，超大回 413 `device_request_too_large`。APNs 暫停配置時，已註冊裝置仍可回報／查詢。回報與雜湊 credential、裝置 token 一起持久保存；重新註冊或 token 輪替保留最新回報，刪除、90 天過期或有效的 APNs 410 清除時一併移除。回報沒有另外建立自動重送排程或推播 outbox。

## 快取、期限與部署方式

一個程序內只有一個輪詢工作，CAP 最多 4 個並行下載。每次請求預設 10 秒、整輪最長 60 秒；HTTP 429 遵循 Retry-After（上限 1 小時），其他失敗 30 秒起指數退避至 30 分鐘。來源只允許固定官方 Feed，以及 `alerts.ncdr.nat.gov.tw/Capstorage/DGPA/<year>/workschoolclose_cap/*.cap` 的 HTTPS 路徑；禁止重新導向、其他主機、URL 金鑰傳播、DOCTYPE／ENTITY、過深 XML、超量項目與過大串流。

磁碟狀態以原子更名寫入，檔案權限 0600。保存可重驗證的原始 CAP（最多 500 則、整份狀態上限 4 MiB），以及有限裝置清單與各台最新回報（裝置狀態檔上限 8 MiB）。資料夾及 `.env` 已排除版本控制，沒有跟 weather-proxy 共用任何 secret。

Dockerfile 使用 Node 22、不以 root 跑 App。未執行 Docker build 或發布映像；部署時自行配置 secrets、HTTPS reverse proxy、備份與持久 volume。**此實作是持續運行的單一 Node 程序，需單一常駐 instance；不應直接放在沒有常駐背景計時器與持久磁碟的 request-only serverless function，也不要用多個副本共享同一狀態檔。** 服務重啟時會先正式同步來源再提供資料。

後續可申請 NCDR 官方 HTTPS 推送，以減少輪詢延遲並保留輪詢補漏；目前沒有啟用該端點、申請審核或對外发送任何資料。

## 驗證

`npm test` 使用 Node 內建測試器，涵蓋真实 CAP、空 Feed、舊公告日期、CAP 更新／撤銷、XML namespace／DTD／超量、來源 URL 白名單、超時、429、單一抓取、來源失敗 503、磁碟恢復、裝置 credential/限速、APNs 簽章與推播回應，以及手機回報的認證、排序、重複、時鐘差異、持久保存、重新註冊／刪除、來源異常和台灣跨日狀態。測試注入本機 fetch／HTTP2 transport，不需真實外部憑證。

尚未驗證：正式 NCDR API Key 回應是否仍使用相同 CAP link 路徑（不同時會明確報來源錯誤，不會放寬白名單）、正式 APNs credentials、實際裝置在背景／低耗電／强制關閉狀態的行為，以及容器部署。這些是正式上線前的實際環境整合工作，不得把本機通過測試描述為已上線。
