# 停班停課服務部署（Cloud Run Job + service + Firestore）

2026-09-24：程式與測試完成（`npm test` 100 通過、7 個 Emulator 測試略過；Firestore Emulator 全套 107 通過）。
資料庫、TTL、索引豁免、secret、映像、service、Job、Scheduler 與 APNs 推播都已就緒並以 `history` 來源運行中（2026-10-06 起；`open-data` 在 10-05 被 NCDR 擋下）；告警通道與三個 policy 已建，absence 告警實測寄達；只剩真機推播驗證（2026-10-03 已完成），見最下方「執行紀錄」。
2026-10-02：為了成本，輪詢由每 5 分鐘改為每 30 分鐘，快照上限改為 1 小時，absence 告警改為 2 小時（新視窗尚未重測）；程式與映像沒有變，見「成本」與「執行紀錄」。
2026-10-03：1.8.0（40）上架後，擁有者手機以 App Store build 首次對正式服務登記（`devices` 0 → 1），強制 revision 改變的推播 `accepted=1`、擴充功能抓到 Feed、橫幅送達：真機推播驗證完成，production APNs 與 `aps-environment` 的搭配確認無誤，見「執行紀錄」。
每一步實際執行後，把讀回的結果寫進最下方的「執行紀錄」，沒做過的不要寫成做過。
設計依據見 `docs/DISASTER-PREVIEW.md` 與 `README.md`；本頁只講怎麼部署、怎麼看、怎麼救。

## 形狀

Cloud Scheduler 每 30 分鐘（每小時的 5 分與 35 分）啟動 Cloud Run **Job** `rainyclock-dayoff-poll`（`node src/job.js`）：
取租約、抓 NCDR、一筆交易寫入 Firestore、續傳推播、釋放租約、印一行摘要、`process.exit`。
頻率是成本決定的（見「成本」）：公告出現在來源後，最慢約 30 分鐘才會被抓到並推播。
Cloud Run **service** `rainyclock-dayoff`（`node src/server.js`）只讀 Job 寫好的 `state/current`
回覆手機，本身沒有輪詢、沒有金鑰、沒有磁碟。兩者用**同一個映像 digest**、各自的 service
account，只在具名資料庫 `dayoff-production` 上有權限。沿用 `weather-proxy/membership/MAINTENANCE.md`
的作法：不要用公開 URL 當 Job 的入口，Scheduler 打的是 Google 管理 API。

## 資源名稱

| 項目 | 值 |
| --- | --- |
| 專案／地區 | `rainyclock` / `asia-east1` |
| Firestore 資料庫 | `dayoff-production`（Standard、Native、刪除保護、`firestore.rules` 全部拒絕） |
| 文件前綴 | `dayoffNamespaces/dayoff_production_v1/` |
| Service | `rainyclock-dayoff` |
| Job | `rainyclock-dayoff-poll`（1 task、`--task-timeout 600s`、`--max-retries 1`） |
| Scheduler | `rainyclock-dayoff-poll`（`5,35 * * * *`、`Asia/Taipei`，每 30 分鐘） |
| Service account | `rainyclock-dayoff-service@`、`rainyclock-dayoff-job@`、`rainyclock-dayoff-scheduler@`（皆 `rainyclock.iam.gserviceaccount.com`） |
| Secrets | `dayoff-ncdr-api-key`（環境變數）、`dayoff-apns-key`（`.p8` 檔案掛載） |
| 映像 | `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:<digest>` |
| Log 指標 | `dayoff_job_runs`、`dayoff_job_failures`、`dayoff_broadcast_incomplete` |
| 告警 | `alerts/absence.yaml`、`alerts/failed-executions.yaml`、`alerts/broadcast-incomplete.yaml` |

不得重用任何 `membership-*` 資料庫，也不得退回 `(default)`；`src/runtime.js` 拒絕 `(default)`，
但只有人能防止建立第二個同名資料庫，所以第 2 步先 `list` 再 `create`。

## 由擁有者親手完成、無法寫成指令的事

1. NCDR 會員 API Key（https://alerts.ncdr.nat.gov.tw/web/developer/alerts-api ）——只進 Secret
   Manager，不進 repo、shell history 或 log。
2. Apple 開發者網站：為 team `MQJ88U9NAJ` 建一把 **APNs** auth key（與 WeatherKit／IAP 金鑰分開；
   一個 team 最多兩把 APNs key），下載 `.p8` 一次、記下 Key ID，上傳到 Secret Manager 後刪除下載檔。
3. 確認 App Store／TestFlight 封存的 `aps-environment` 是 `production`（entitlement 檔寫的是
   `development`，Xcode 在 archive 時改成 production），且 `com.shukaihu.RainyClock` 已開 Push
   Notifications capability。`APNS_PRODUCTION` 必須跟裝置的環境一致，否則 APNs 回 `BadDeviceToken`。
   （2026-10-03 已用 App Store 1.8.0 build 40 實測：`APNS_PRODUCTION=true` 對發行簽章的裝置 `accepted=1`、橫幅送達，
   見執行紀錄。）
4. Monitoring 通知管道（目前專案沒有任何一個）與下面第 9 步的告警。
5. 第一次 Job 成功後，把 Cloud Run 給的 URL（不含路徑、不經轉址、不用自訂網域）填進
   `RainyClock/Info.plist` 的 `DayOffServiceURL`；1.8.0 才翻 `supportsTemporaryClosures`。
6. 部署後把每個資源、digest、驗證結果記進本頁「執行紀錄」、`docs/STATUS-IOS.md`、
   `docs/DISASTER-PREVIEW.md`、`README.md`「快取、期限與部署方式」與 `CLAUDE.md`。

## 部署順序

在 repo 根目錄執行；`<...>` 是擁有者填的值。每一步都是冪等或先查再建；照順序做，
不要跳到後面的步驟——service 要先有 URL，Job 才能拿到 `DAYOFF_SERVICE_URL`。

### 1. 專案與 API

```sh
gcloud config set project rainyclock
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com firestore.googleapis.com \
  secretmanager.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com
```

### 2. Firestore：資料庫、TTL、索引豁免、規則

```sh
gcloud firestore databases list   # 確認 dayoff-production 不存在；絕不建立重複的資料庫
gcloud firestore databases create --database=dayoff-production --location=asia-east1 \
  --type=firestore-native --edition=standard --delete-protection
for cg in devices caps broadcasts retries; do
  gcloud firestore fields ttls update expiresAt --collection-group=$cg --database=dayoff-production --enable-ttl
done
gcloud firestore indexes fields update noticesJSON --collection-group=state --database=dayoff-production --disable-indexes
gcloud firestore indexes fields update xml --collection-group=caps --database=dayoff-production --disable-indexes
(cd dayoff-service && npx firebase-tools deploy --only firestore:rules --project rainyclock)
gcloud firestore fields ttls list --database=dayoff-production   # 預期四筆 ACTIVE
```

索引豁免是必要的：Firestore 索引的字串上限 1500 bytes，`noticesJSON` 與 `xml` 都會超過，沒豁免就
寫不進去。`devices.updatedAt`（容量計數）與 `devices.deviceToken`（410 查詢）維持自動單欄索引，
不要一併豁免。規則部署失敗（firebase-tools 沒連到專案）可以略過：手機從不直接連 Firestore，
兩個 service account 由 IAM 管，deny-all 規則只擋 client SDK。

### 3. Service account 與 IAM

```sh
gcloud iam service-accounts create rainyclock-dayoff-service --display-name="RainyClock day-off HTTP service"
gcloud iam service-accounts create rainyclock-dayoff-job --display-name="RainyClock day-off poll job"
gcloud iam service-accounts create rainyclock-dayoff-scheduler --display-name="RainyClock day-off scheduler"
for SA in rainyclock-dayoff-service rainyclock-dayoff-job; do
  gcloud projects add-iam-policy-binding rainyclock \
    --member="serviceAccount:$SA@rainyclock.iam.gserviceaccount.com" --role=roles/datastore.user \
    --condition='title=DayoffProductionDatabaseOnly,expression=resource.name=="projects/rainyclock/databases/dayoff-production"'
done
```

### 4. Secrets（Job 才拿得到；service 一個都沒有）

```sh
gcloud secrets create dayoff-ncdr-api-key --replication-policy=user-managed --locations=asia-east1
read -rs NCDR_KEY; printf '%s' "$NCDR_KEY" | gcloud secrets versions add dayoff-ncdr-api-key --data-file=-; unset NCDR_KEY
gcloud secrets create dayoff-apns-key --replication-policy=user-managed --locations=asia-east1
gcloud secrets versions add dayoff-apns-key --data-file=<PATH_OUTSIDE_REPO>/AuthKey_<APNS_KEY_ID>.p8   # 之後刪除下載檔
for S in dayoff-ncdr-api-key dayoff-apns-key; do
  gcloud secrets add-iam-policy-binding $S \
    --member="serviceAccount:rainyclock-dayoff-job@rainyclock.iam.gserviceaccount.com" --role=roles/secretmanager.secretAccessor
done
```

`read -rs` 在 repo 之外的終端機執行，金鑰不會出現在指令列或 history。

### 5. 建置一個映像，兩個工作共用

```sh
TAG=$(git rev-parse --short HEAD)
gcloud builds submit dayoff-service --tag asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG
IMAGE=$(gcloud artifacts docker images describe \
  asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG \
  --format='value(image_summary.fully_qualified_digest)')
```

`.gcloudignore` 排除 `test/`、`.env*`、任何 `.p8`；`Dockerfile` 只複製 `src/` 與 `apns.js`。
之後一律用 `$IMAGE`（digest），service 與 Job 永遠指向同一個。

### 6. Service

```sh
gcloud run deploy rainyclock-dayoff --region=asia-east1 --image="$IMAGE" --command=node --args=src/server.js \
  --service-account=rainyclock-dayoff-service@rainyclock.iam.gserviceaccount.com \
  --allow-unauthenticated --ingress=all --cpu=1 --memory=512Mi --concurrency=80 --timeout=30 \
  --min-instances=0 --max-instances=3 \
  --set-env-vars=GOOGLE_CLOUD_PROJECT=rainyclock,DAYOFF_FIRESTORE_DATABASE=dayoff-production,DAYOFF_NAMESPACE=dayoff_production_v1,MAX_CACHE_AGE_MS=3600000,SNAPSHOT_CACHE_MS=5000,PUSH_CONFIGURED=1,APNS_PUSH_MODE=alert,TRUST_PROXY=1
URL=$(gcloud run services describe rainyclock-dayoff --region=asia-east1 --format='value(status.url)')
curl -sS -i "$URL/health"          # 第一次 Job 跑完前是 503 not_configured，pushConfigured:true、pushMode:"alert"
curl -sS -i -X DELETE "$URL/v1/devices" -H 'Content-Type: application/json' --data '{"x":1}'   # 預期 400 invalid_device_request
```

那個 DELETE 證明 body 有被轉送、途中沒有轉址；iOS 端的裝置請求拒絕任何轉址。

### 7. Job，先手動跑一次

```sh
gcloud run jobs create rainyclock-dayoff-poll --region=asia-east1 --image="$IMAGE" --command=node --args=src/job.js \
  --service-account=rainyclock-dayoff-job@rainyclock.iam.gserviceaccount.com \
  --tasks=1 --parallelism=1 --max-retries=1 --task-timeout=600s --cpu=1 --memory=512Mi \
  --set-env-vars=GOOGLE_CLOUD_PROJECT=rainyclock,DAYOFF_FIRESTORE_DATABASE=dayoff-production,DAYOFF_NAMESPACE=dayoff_production_v1,POLL_INTERVAL_MS=1800000,REQUEST_TIMEOUT_MS=10000,BROADCAST_CONCURRENCY=16,BROADCAST_PAGE_SIZE=200,LEASE_MS=120000,LEASE_RENEW_MS=30000,RUN_BUDGET_MS=420000,DAYOFF_SERVICE_URL=$URL,APNS_TEAM_ID=MQJ88U9NAJ,APNS_KEY_ID=<APNS_KEY_ID>,APNS_TOPIC=com.shukaihu.RainyClock,APNS_PRODUCTION=<true|false>,APNS_PUSH_MODE=alert,APNS_PRIVATE_KEY_PATH=/secrets/apns/AuthKey.p8 \
  --set-secrets=NCDR_API_KEY=dayoff-ncdr-api-key:latest,/secrets/apns/AuthKey.p8=dayoff-apns-key:latest
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job"' --limit=3 --format=json
curl -sS -i "$URL/health" && curl -sS "$URL/v1/suspensions" | head -c 400 && curl -sS "$URL/health/details"   # 現在 200，有 revision 與 notices
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 & \
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait; wait   # 重疊證明：其中一份摘要必須是 skipped:"lease_held"
```

`RUN_BUDGET_MS`（420 s）必須小於 `--task-timeout`（600 s），留給 `finally` 釋放租約、關閉連線；
`LEASE_RENEW_MS` 必須小於 `LEASE_MS`，`src/job.js` 啟動時會檢查。

### 8. Scheduler

```sh
gcloud run jobs add-iam-policy-binding rainyclock-dayoff-poll --region=asia-east1 \
  --member="serviceAccount:rainyclock-dayoff-scheduler@rainyclock.iam.gserviceaccount.com" --role=roles/run.invoker
gcloud scheduler jobs create http rainyclock-dayoff-poll --location=asia-east1 \
  --schedule='5,35 * * * *' --time-zone=Asia/Taipei \
  --uri=https://run.googleapis.com/v2/projects/rainyclock/locations/asia-east1/jobs/rainyclock-dayoff-poll:run \
  --http-method=POST --message-body='{}' --headers=Content-Type=application/json \
  --oauth-service-account-email=rainyclock-dayoff-scheduler@rainyclock.iam.gserviceaccount.com \
  --oauth-token-scope=https://www.googleapis.com/auth/cloud-platform \
  --attempt-deadline=60s --max-retry-attempts=3 --min-backoff=10s
gcloud scheduler jobs run rainyclock-dayoff-poll --location=asia-east1
gcloud run jobs executions list --job=rainyclock-dayoff-poll --region=asia-east1 --limit=3
```

用的是 Scheduler SA 的 **OAuth access token**（scope `cloud-platform`）打管理 API，不是打 Cloud Run
公開網址的 OIDC token。Scheduler 回 200 只代表 execution 啟動了，抓取成功與否看 Job 的摘要。
排程是每 30 分鐘，選每小時的 5 分與 35 分而不是 0 分與 30 分：改頻率前 9 天裡僅有的兩次
`upstream_rate_limited` 都發生在整點（2026-09-29 15:00 與 20:00）。已存在的 Scheduler 改排程用
`gcloud scheduler jobs update http rainyclock-dayoff-poll --location=asia-east1 --schedule='5,35 * * * *'`。
`POLL_INTERVAL_MS`（§7）、`MAX_CACHE_AGE_MS`（§6）、告警視窗（§9）與 App 的 `DisasterMapStatus.maximumFeedAge`
都跟著這個頻率，要改就一起改，並先重算「成本」。

### 9. 告警（1.8.0 翻開開關之前必須存在）

```sh
gcloud beta monitoring channels create --display-name=owner-email --type=email --channel-labels=email_address=<OWNER_EMAIL>
gcloud beta monitoring channels list --format='value(name)'   # 取 <CHANNEL_ID>，填進 alerts/*.yaml
# 沒裝 beta/alpha 元件時，用 REST API 送 alerts/*.json（2026-09-24 實際採用）：
#   TOKEN=$(gcloud auth print-access-token); curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#     https://monitoring.googleapis.com/v3/projects/rainyclock/notificationChannels --data '{"type":"email","displayName":"owner-email","labels":{"email_address":"<OWNER_EMAIL>"},"enabled":true}'
#   curl -X POST ... https://monitoring.googleapis.com/v3/projects/rainyclock/alertPolicies --data @dayoff-service/alerts/<name>.json
#   改既有 policy（2026-10-02 改視窗時採用）：curl -X PATCH ... https://monitoring.googleapis.com/v3/projects/rainyclock/alertPolicies/<POLICY_ID> --data @dayoff-service/alerts/<name>.json
gcloud logging metrics create dayoff_job_runs --description='day-off poll executions' \
  --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job"'
gcloud logging metrics create dayoff_job_failures --description='day-off poll runs with ok=false' \
  --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job" AND jsonPayload.ok=false'
gcloud logging metrics create dayoff_broadcast_incomplete --description='day-off broadcast not done' \
  --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job" AND jsonPayload.broadcast.state!="done" AND jsonPayload.broadcast.state!=""'
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait   # 讓 dayoff_job_runs 先有一個資料點，absence 條件才建得起來
gcloud alpha monitoring policies create --policy-from-file=dayoff-service/alerts/absence.yaml
gcloud alpha monitoring policies create --policy-from-file=dayoff-service/alerts/failed-executions.yaml
gcloud alpha monitoring policies create --policy-from-file=dayoff-service/alerts/broadcast-incomplete.yaml
gcloud billing budgets create --billing-account=<BILLING_ACCOUNT_ID> --display-name=rainyclock-dayoff --budget-amount=5USD --threshold-rule=percent=1.0
```

三個告警裡 `absence.yaml` 是唯一不可省的：Scheduler 死掉不會產生失敗的 execution，只有「2 小時沒有
摘要」（連續錯過四次輪詢）看得出來。來源失敗（`upstream_*`）退出碼是 0，也不會是失敗的 execution，靠
`dayoff_job_failures`（`broadcast-incomplete.yaml`：2 小時內多於 2 次，也就是連續四次輪詢裡有三次）。
`failed-executions.yaml` 的 600 秒視窗與輪詢頻率無關。三份 YAML 沒有對著 Monitoring API 驗證過：建立時
`gcloud` 拒絕就改欄位，建立後要用 `gcloud scheduler jobs pause` 停超過 2 小時（條件 7200 秒，再加對齊與
評估延遲），確認 absence 告警真的寄信，再 `resume`。最後一次成功輪詢滿 1 小時起（暫停後 30 分鐘到 1 小時之間）
service 回 503 `stale_cache`、手機退回保守規則，直到 `resume` 後第一次成功輪詢，所以挑沒有颱風的時段做。
2 小時視窗還沒有實測過；2026-09-24 的實測是 15 分鐘視窗（約 20 分鐘寄達）。

### 10. 驗收（記進「執行紀錄」，不能只記「建好了」）

- [ ] 第一次手動 execution 成功，`$URL/health` 200，`/v1/suspensions` 有 `revision` 與 `checkedAt`。
- [ ] 兩個 execution 重疊，其中一份摘要 `skipped:"lease_held"`，另一份 `refreshed:true`。
- [ ] `DELETE /v1/devices` 帶垃圾 JSON 回 400 `invalid_device_request`。
- [ ] Scheduler 手動派送一次，`executions list` 看得到對應的 execution。
- [x] TestFlight 裝置註冊成功（201），強制一次 revision 改變（在 Firestore console 把
      `state/current.revision` 改成任意別的字串再 `execute` 一次：下一次抓取會判定內容改變、建立 claim；
      或等真實公告），log 只有**一個** `push_batch`，通知服務擴充功能改寫了橫幅。
      （2026-10-03 以 App Store 1.8.0 build 40 完成，不是 TestFlight；見執行紀錄 2026-10-03 15:18–15:23。）
- [ ] 下一個 execution 的摘要 `changed:false`、`broadcast:null`。
- [ ] 暫停 Scheduler 超過 2 小時，absence 告警寄達（最後一次成功輪詢滿 1 小時起 service 回 503
      `stale_cache`，是預期的）；`resume` 後告警自動關閉。
- [ ] `gcloud firestore fields ttls list` 四筆 ACTIVE；`/health/details` 的 `storage:"firestore"`。

## 環境變數

Service（`rainyclock-dayoff`，都不是秘密）：

| 變數 | 值 | 說明 |
| --- | --- | --- |
| `PORT` | Cloud Run 注入 | 映像預設 8080 |
| `HOST` | `0.0.0.0` | 映像預設 |
| `GOOGLE_CLOUD_PROJECT` | `rainyclock` | `DAYOFF_FIRESTORE_PROJECT` 可覆寫 |
| `DAYOFF_FIRESTORE_DATABASE` | `dayoff-production` | 必填，`(default)` 被拒 |
| `DAYOFF_NAMESPACE` | `dayoff_production_v1` | 文件前綴 |
| `MAX_CACHE_AGE_MS` | `3600000` | 超過 1 小時（連續兩次輪詢沒成功）的快照回 503 `stale_cache`；程式預設仍是 `900000`，所以一定要明設 |
| `SNAPSHOT_CACHE_MS` | `5000` | 每個 instance 每 5 秒最多讀一次 `state/current` |
| `PUSH_CONFIGURED` | `1` | 只是宣告 Job 有 APNs；service 本身沒有金鑰 |
| `APNS_PUSH_MODE` | `alert` | 必須與 Job 相同 |
| `TRUST_PROXY` | `1` | 限速以最後一個 `X-Forwarded-For`（Cloud Run 接上的真正來源）為鍵 |

Job（`rainyclock-dayoff-poll`）：

| 變數 | 值 | 說明 |
| --- | --- | --- |
| `GOOGLE_CLOUD_PROJECT`、`DAYOFF_FIRESTORE_DATABASE`、`DAYOFF_NAMESPACE` | 同 service | 兩者必須讀同一份文件 |
| `POLL_INTERVAL_MS` | `1800000` | 與排程相同（30 分鐘）。在 Job 裡只決定成功後回報的 `nextAttemptAt`，不會擋下一次執行（擋的只有失敗後的退避）；程式預設仍是 `300000` |
| `REQUEST_TIMEOUT_MS` | `10000` | 每個 NCDR 請求 |
| `BROADCAST_CONCURRENCY` | `16` | 1..64；APNs 回 429 時降低 |
| `BROADCAST_PAGE_SIZE` | `200` | 50..500；一次崩潰最多重送一頁 |
| `LEASE_MS` / `LEASE_RENEW_MS` | `120000` / `30000` | 續約必須短於租約 |
| `RUN_BUDGET_MS` | `420000` | 必須小於 task timeout 600 s |
| `DAYOFF_SERVICE_URL` | `$URL` | 內容改變時暖機一次；https、只有 origin |
| `APNS_TEAM_ID` | `MQJ88U9NAJ` | |
| `APNS_KEY_ID` | `<APNS_KEY_ID>` | 輪替時改這裡 |
| `APNS_TOPIC` | `com.shukaihu.RainyClock` | |
| `APNS_PRODUCTION` | `true`（TestFlight／App Store）或 `false`（Xcode Debug） | 必填，沒有預設 |
| `APNS_PUSH_MODE` | `alert` | |
| `APNS_PRIVATE_KEY_PATH` | `/secrets/apns/AuthKey.p8` | Secret 掛載路徑 |
| `NCDR_SOURCE` | `member`、`open-data` 或 `history` | `history`（2026-10-06 起的正式值）打 NCDR 免金鑰的歷史查詢 API（`DAYOFF-SPEC.md` §2.2）：最近兩個台灣日各自送出的公告、每頁 10 筆、請求間隔 3 秒，丟掉 `expires` 已過的，CAP 檔照舊抓與驗證。`open-data` 是 data.gov.tw 資料集 20457 的免金鑰網址，**2026-10-05 起回「請先登入會員」**（`source_login_required`），留著等它回來。`member` 要 NCDR 會員金鑰（個人信箱申請不到）。第四個值 `fixture` 只給 sandbox Job（namespace 不含 `sandbox` 即啟動失敗 `fixture_not_allowed`） |
| `NCDR_API_KEY` | secret `dayoff-ncdr-api-key:latest` | `--set-secrets` 注入的環境變數；只在 `member` 來源，`open-data` 與 `history` 時不要掛（`jobConfig` 會拒絕） |
| `CLOUD_RUN_EXECUTION` | Cloud Run 注入 | 租約的 owner；同一 execution 的 task 重試可接管 |

四個 `APNS_*` 設定全留白就是只抓不推；填一半會啟動失敗（`invalid_apns_configuration`）。

## IAM

- `rainyclock-dayoff-service@` 與 `rainyclock-dayoff-job@`：各自只有條件式 `roles/datastore.user`，
  條件限制 `projects/rainyclock/databases/dayoff-production`；沒有其他資料庫、沒有 Vertex／TTS。
- `rainyclock-dayoff-job@` 另有兩個 secret 的 `roles/secretmanager.secretAccessor`（逐 secret 授，
  不給專案層級）。service SA 沒有任何 secret。
- `rainyclock-dayoff-scheduler@`：只在 **Job** `rainyclock-dayoff-poll` 上有 `roles/run.invoker`，
  沒有專案層級授權、沒有 Firestore 權限。Job 不綁 `allUsers`／`allAuthenticatedUsers`。
- Service `rainyclock-dayoff` 是 `--allow-unauthenticated`：手機沒有 Google 身分。限速是每個
  instance 記憶體內的 30 次／分鐘，`max-instances 3` 表示每個來源最多約 90 次／分鐘；它擋濫用，
  不是安全邊界。
- 部署者要有 Cloud Run／Scheduler 管理權限與三個 SA 的 `iam.serviceAccounts.actAs`；不要把管理
  權限給實際跑排程的 SA。

## 秘密處理與輪替

- 兩個 secret 都是 `user-managed`、只在 `asia-east1`。加入版本一律用 `--data-file=-` 或 repo 外的
  檔案路徑；不要 `echo`。`.gcloudignore` 與 `.gitignore` 都排除 `*.p8`。
- Job 只印一行摘要，摘要與 stderr 診斷都沒有金鑰、token、installationId、URL 或原始錯誤文字
  （`test/job.test.js` 用假金鑰驗證）。
- APNs 金鑰輪替（`apns_credentials_rejected` 告警、或 Apple 要求時）：

```sh
gcloud secrets versions add dayoff-apns-key --data-file=<PATH_OUTSIDE_REPO>/AuthKey_<NEW_KEY_ID>.p8
gcloud run jobs update rainyclock-dayoff-poll --region=asia-east1 --update-env-vars=APNS_KEY_ID=<NEW_KEY_ID>
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait
gcloud secrets versions disable <OLD_VERSION> --secret=dayoff-apns-key
```

  被拒時 claim 停在 `sending` 並保留租約，那一次不計入 3 次嘗試（否則三個 tick 就會把 revision 用盡），
  換鑰後的那次執行從游標續傳，不重送已送出的頁。
- NCDR key 輪替：加入新版本後 `gcloud run jobs update ... --update-secrets=NCDR_API_KEY=dayoff-ncdr-api-key:latest`
  （Job 每次執行都重新讀 `latest`，其實只要停用舊版本並執行一次確認）。

## Sandbox 堆疊（隨時在 Debug 手機上製造一次真正的推播）

正式 Job 只在 revision 改變時推播，NCDR 又只在颱風期間才變，所以「手機收到推播 → 通知擴充功能改寫
→ 鬧鐘判斷」在平常無法驗證。Sandbox 堆疊用**同一個映像 digest**（≥ 含 `NCDR_SOURCE=fixture` 的版本）跑第二組 service ＋ Job，差別只有：

| 項目 | 正式 | Sandbox |
| --- | --- | --- |
| Service | `rainyclock-dayoff` | `rainyclock-dayoff-sandbox`（其餘旗標與正式相同） |
| Job | `rainyclock-dayoff-poll` | `rainyclock-dayoff-poll-sandbox` |
| `DAYOFF_NAMESPACE` | `dayoff_production_v1` | `dayoff_sandbox_v1`（同一個 `dayoff-production` 資料庫） |
| `NCDR_SOURCE` | `open-data` | `fixture`：讀 `dayoffNamespaces/dayoff_sandbox_v1/fixture/current`，不連 NCDR |
| `APNS_PRODUCTION` | `true` | `false`（Xcode Debug 裝置的 token 在 APNs sandbox） |
| Scheduler | `5,35 * * * *`（每 30 分鐘） | **沒有**；每次輪詢都是 `deploy/fixture.sh` 或手動 `jobs execute` |
| Service account、secret、IAM | 相同（`.p8` 掛載同一個 `dayoff-apns-key`；`datastore.user` 條件是整個資料庫） | 相同，不必新增 |

正式環境不受影響：`src/job.js` 在 namespace 不含 `sandbox` 時拒絕 `fixture` 來源，正式 Job 的
`open-data` 來源不讀 `fixture/current`，`src/fixture-cli.js` 拒絕寫入非 sandbox namespace。

### 部署（一次；換 digest 時重跑）

```sh
# 先照「更新程式」那節用含 fixture 來源的 HEAD 建新 image；sandbox 與正式要同 digest，所以之後也用同一個 IMAGE 重佈正式（gcloud run deploy rainyclock-dayoff / jobs update rainyclock-dayoff-poll）
# 執行紀錄裡正式在跑的 sha256:d4024db9… 早於 NCDR_SOURCE=fixture，拿它部署 sandbox 的第一次執行會以 invalid_configuration 失敗；sandbox 現行 digest 見「執行紀錄（sandbox）」
# APNS_KEY_ID 與正式 Job 相同（同一把 .p8 兩個 gateway 都能用）
IMAGE=asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:<digest> \
APNS_KEY_ID=<APNS_KEY_ID> sh dayoff-service/deploy/sandbox.sh
SANDBOX_URL=$(gcloud run services describe rainyclock-dayoff-sandbox --region=asia-east1 --format='value(status.url)')
curl -sS "$SANDBOX_URL/health/details"   # 第一次執行後：state ready、source "fixture"、noticeCount 0（沒有 fixture = 空 Feed）
```

腳本會部署 service、建立／更新 Job（`NCDR_SOURCE=fixture`、`APNS_PRODUCTION=false`、`DAYOFF_SERVICE_URL`
指向 sandbox service）、手動執行一次，**不建 Scheduler**。

### 製造一次推播

```sh
# 本機以擁有者的 gcloud ADC 寫 fixture（project rainyclock、資料庫 dayoff-production、namespace dayoff_sandbox_v1），
# 再執行 sandbox Job 一次（--wait），推播當場發生
sh dayoff-service/deploy/fixture.sh set --county 新北市 --district 板橋區                  # 明天停止上班、停止上課
sh dayoff-service/deploy/fixture.sh set --county 臺東縣 --when today --scope school        # 今天照常上班、停止上課
sh dayoff-service/deploy/fixture.sh set --county 連江縣 --day-part morning                 # 明天上午停止上班、停止上課
sh dayoff-service/deploy/fixture.sh show                                                   # 只看，不執行 Job
sh dayoff-service/deploy/fixture.sh clear                                                  # 空 Feed，也是一次 revision 改變 → 也推播
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll-sandbox" AND jsonPayload.event="dayoff_job"' --limit=3 --format=json
curl -sS "$SANDBOX_URL/v1/suspensions"   # 手機的通知擴充功能讀到的就是這個
```

同一份 fixture 再執行一次是 `changed:false`、`broadcast:null`，不會重複推播。沒有 Scheduler，所以最後一次
執行 1 小時後 sandbox service 回 503 `stale_cache`（手機退回保守規則），要再看就再執行一次 Job。
`gcloud logging read` 用正式的 metric 過濾不到 sandbox Job（`job_name` 不同），三個告警都不會被 sandbox 觸發。

### 手機端

1. **不改任何 plist。** App 自己選 sandbox：`AppEnvironment.dayOffServiceURL` 在每個 Debug build
   （`RainyClock`、`RainyClock Membership Local`、Debug Sandbox 皆是，因為它們都以 `aps-environment = development`
   簽章，token 只在 APNs sandbox）讀 `RainyClock/Info.plist` 的 `DayOffSandboxServiceURL`，Release 才讀
   `DayOffServiceURL`。確認 `$SANDBOX_URL` 等於 `DayOffSandboxServiceURL`（預期
   `https://rainyclock-dayoff-sandbox-510427696731.asia-east1.run.app`；Cloud Run 若印出別的 host，要更新的是
   `DayOffSandboxServiceURL`，不是 `DayOffServiceURL`），然後從 Xcode 以 Debug 裝到真機（模擬器沒有 APNs token）。
   通知擴充功能用的是 App 註冊時寫進 `DayOffSharedState.serviceURL` 的同一個網址，擴充功能那邊不必改。
2. 在 App 開啟停班停課功能、確認縣市／行政區，讓 App 向 sandbox service `POST /v1/devices`（201）。
   `curl -sS "$SANDBOX_URL/health"` 的 `pushConfigured:true`；Firestore console 的
   `dayoffNamespaces/dayoff_sandbox_v1/devices/` 多一筆（不要抄 token 到任何地方）。
3. `sh dayoff-service/deploy/fixture.sh set --county <手機設定的縣市> --district <手機設定的行政區>`；
   腳本印出這次 execution 名稱與它自己的摘要（`skipped changed broadcast.state broadcast.accepted`，
   依 execution 名稱過濾，不會拿到上一次的），應為 `changed:true`、`broadcast.accepted:1`；`skipped` 非空
   （`lease_held`／`backoff`）就是這次沒輪詢。手機在幾秒內收到橫幅，內容由通知擴充功能改寫成
   符合本機行政區的文字。鬧鐘要等 App 打開才會跟著改；**距上一次 Job 超過 1 小時就先重跑一次 Job**
   （`gcloud run jobs execute rainyclock-dayoff-poll-sandbox --region=asia-east1 --wait`，內容不變不會推播），
   否則 App 拿到 503 會照規則恢復鬧鐘，看起來像沒有套用。
4. 換 `--scope`／`--when`／`--day-part` 各跑一次，最後 `clear`，確認每次都是新的 revision、都收到一則、
   而且鬧鐘判斷符合 `docs/dayoff-fixtures.json` 的預期。
5. 結束後不必還原任何設定；TestFlight／App Store（Release）build 一直走正式 URL 與 production APNs。

### 執行紀錄（sandbox）

### 2026-09-28 18:43 – 09-29 00:07（真機：iPhone 16 Pro，Debug Sandbox build）

- `fixture.sh set --county 臺南市`（18:43，明天＝9/29）→ `accepted=1`；擴充功能 `GET /v1/suspensions` 200，
  通知改寫成時效性、有聲，睡眠專注模式下仍送達。打開 App 後 9/29 略過，receipt `applied`。
- 再發一次時，擴充功能拿下一個會響的 9/30 比對，說「與你設定的地區無關」：App 端錯誤，`7954488` 修正。
- 23:50 App 拿到 503（上一次 Job 已超過 15 分鐘），照規則恢復 9/29；23:51 重發 → 有聲通知（正確，當時 9/29 未略過）。
  23:53 打開 App 沒有重抓：5 分鐘節流擋住了推播後的更新，App 端錯誤，本次修正（推播時間晚於上次嘗試就不節流）。
- 23:58 App 抓到 200，receipt `applied`（revision `ef03b536c0`）。00:05 重跑 Job：`changed=false`、未推播。
- 00:07 `fixture.sh set --county 臺南市 --when today`（今天＝9/29，已略過）→ `accepted=1`，擴充功能 200；
  手機顯示安靜的「9/29: that day's alarm has already been skipped.」。00:12 App 抓到 revision `5b94fa0e15`，receipt `applied`。

### 2026-09-28 01:54–02:05（Claude 執行，讀回值）

- Cloud Build `d9d55807-0981-472f-ba6a-d115af119378`，37 秒，SUCCESS，來源 commit `df5ec48`（含 fixture 來源）；
  digest `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:20a7a485862bc2588bfd202d5a8dc11556c91030f4143ccc55f3d7c5eccdfce3`。
  **正式堆疊仍跑 `sha256:d4024db9…`**，未重新部署；正式與 sandbox 暫時不同 digest，下次正式更新時對齊。
- `IMAGE=<上面 digest> APNS_KEY_ID=H9SMW8923R sh deploy/sandbox.sh` → service `rainyclock-dayoff-sandbox`
  revision `rainyclock-dayoff-sandbox-00001-fkk`（URL `https://rainyclock-dayoff-sandbox-510427696731.asia-east1.run.app`），
  Job `rainyclock-dayoff-poll-sandbox`（`NCDR_SOURCE=fixture`、`dayoff_sandbox_v1`、`APNS_PRODUCTION=false`、無 Scheduler）。
  第一次執行 `…-2kxtg`：`source=fixture changed=true noticeCount=0`、broadcast `done`、`accepted=0`（沒有裝置）。
- 第一次 `fixture.sh set` 失敗：本機 ADC 過期（`invalid_grant`）且屬於另一個專案。`7c9b684` 起 `fixture.sh`
  改用 `gcloud auth print-access-token` 的權杖，不再依賴 ADC。
- `fixture.sh set --county 新北市 --district 板橋區` → execution `…-gs5tf`：`changed=true`、broadcast `done`、
  `accepted=0`；sandbox `/v1/suspensions` 回 1 則：`[停班停課通知]新北市板橋區:明天停止上班、停止上課。行政院人事行政總處。`
  （Extreme／Alert／Actual，geocode `65000`）。隨後 `fixture.sh clear` → 0 則。
- 正式堆疊全程不受影響：`source=open-data`、14 則。

**尚未執行**：手機端（Debug build 登記到 sandbox、收到橫幅、擴充功能改寫、隔天鬧鐘被略過）。

## 更新程式

```sh
TAG=$(git rev-parse --short HEAD)
gcloud builds submit dayoff-service --tag asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG
IMAGE=$(gcloud artifacts docker images describe asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG --format='value(image_summary.fully_qualified_digest)')
gcloud run deploy rainyclock-dayoff --region=asia-east1 --image="$IMAGE"
gcloud run jobs update rainyclock-dayoff-poll --region=asia-east1 --image="$IMAGE"
```

只換映像時用上面兩行；要換來源（例如 2026-10-06 的 `open-data` → `history`）就跑 `deploy/deploy.sh`，它會重設 Job 的整組環境變數與 secret。

兩個工作永遠同一個 digest。改 `state/current` 的欄位時先讀 `README.md` 的 schema 段：service 讀的是
Job 寫的文件，兩邊的映像不同會讓 `/v1/suspensions` 直接 503 或送出錯的欄位。
只換 `--image` 不會動環境變數。要重設整組（`--set-env-vars` 會取代全部）就照 §6／§7 或 `deploy/deploy.sh`
的值：漏掉 `MAX_CACHE_AGE_MS` 會退回程式預設的 15 分鐘，在 30 分鐘的排程下每個週期有一半時間回 503 `stale_cache`。

## 運行手冊

一個畫面看完：

```sh
curl -s $URL/health/details | jq
```

可以信任的狀態：`state:"ready"`、`ageMs < 2100000`（約 35 分鐘：一個輪詢週期再加一點）、`job.finishedAt`
在 35 分鐘內、`broadcast` 是 `null` 或 `state:"done"`。不是的話：

```sh
gcloud run jobs executions list --job rainyclock-dayoff-poll --region asia-east1 --limit 5
gcloud run jobs execute rainyclock-dayoff-poll --region asia-east1 --wait
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job"' --limit 3
```

| 看到 | 意思 | 做法 |
| --- | --- | --- |
| `errorCode:"source_login_required"` | NCDR 對這個來源要求登入（2026-10-05 兩個免金鑰的 AlertType feed 都變成這樣；`history` 來源遇到同一面牆也報這個碼） | 換來源：§5 建映像 → `IMAGE=… NCDR_SOURCE=history sh dayoff-service/deploy/deploy.sh`；`history` 也被擋的話只剩申請會員金鑰（`member`） |
| `source_check_failed` 帶 `phase`、`window`、`page`、`requests` | 只有 `history` 來源會附：失敗在索引的哪一天哪一頁（`phase:"index"`）或已經在抓 CAP（`phase:"cap"`） | 配合 `too_many_notices`（單日超過 200 則）、`upstream_rate_limited`（同一頁重試兩次仍 429）、`upstream_timeout`（整輪超過 300 秒）看 |
| `errorCode:"upstream_*"`、`invalid_source_*` | NCDR 端的問題；service 立刻回 503，直到下一次成功輪詢（通常是下一個 tick，約 30 分鐘）。退避上限 30 分鐘剛好等於排程間隔：連續失敗第 7 次起（約 3 小時），或來源回 429 且 `Retry-After` 在 30 分鐘以上（上限 1 小時），下一個 tick 會以 `skipped:"backoff"` 跳過，等於每小時才抓一次，503 可能再多拖 30–60 分鐘 | `nextAttemptAt` 是最早可以再抓的時間，排程要到下一個 5／35 分才會再跑；要提早恢復，過了 `nextAttemptAt` 直接 `jobs execute`，還沒到就在 Firestore console 把 `state/current.nextAttemptAt` 改成 `0`（看得到、有稽核），再 `jobs execute` |
| `skipped:"backoff"` | 上一次失敗的退避還沒到 | 同上；不要把 Cloud Run 的 retry 調高，那只會撞同一個閘門 |
| `skipped:"lease_held"` 連續出現 | 前一個 execution 還在跑或被殺時沒釋放 | 租約最長 `LEASE_MS`（2 分鐘）自動過期，而排程相隔 30 分鐘，所以排程的 tick 出現一次就不正常：看 executions 是否有卡住的 task 或有人同時手動執行；連續兩次 service 就會 `stale_cache` |
| `errorCode:"apns_credentials_rejected"` | APNs 金鑰過期／被撤 | 上面的輪替步驟；被拒的執行不計入嘗試次數，換鑰後 claim 從游標續傳 |
| `broadcast.state:"partial"` 且 `complete:false` | 預算、斷路器或 SIGTERM | task 重試會從游標續傳，之後每個 tick 前進一步（現在相隔 30 分鐘）；連續三次（`attempts:3`）後下一次認領把 claim 標為 `exhausted`、清掉 `pendingBroadcastRevision`，`ok:false` 只告警一次，看 `failed`／`retryPending` 判斷是 APNs 還是我們 |
| `broadcast.state:"exhausted"` | 三次嘗試都沒送完，已停止 | 要再送：在 Firestore console 把 `broadcasts/<rev>` 的 `attempts` 改成 `0`、`state` 改成 `pending`，並把 `state/current.pendingBroadcastRevision` 改回 `<rev>`（看得到、有稽核），再 `jobs execute`；游標會從上次停的地方續傳 |
| `stale_cache` 但 execution 都成功 | 時鐘或 `MAX_CACHE_AGE_MS` 與排程不合 | 排程 30 分鐘、上限 1 小時；先確認 Scheduler 沒被暫停，再看 service 的 `MAX_CACHE_AGE_MS` 是不是還是 `3600000`（沒設會退回程式預設的 15 分鐘） |
| `storage_unavailable` | Firestore 不可用或 IAM 條件錯 | `gcloud projects get-iam-policy rainyclock` 看條件表達式的資料庫名 |

暫停整個功能：`gcloud scheduler jobs pause rainyclock-dayoff-poll --location=asia-east1`。手機在最後一次成功
輪詢滿 1 小時後（暫停後 30 分鐘到 1 小時之間）收到 503 `stale_cache`，會回到自己的保守規則（不會把舊公告當今天的）；
暫停超過 2 小時 absence 告警會寄信，那是預期的。恢復：`resume` 後手動 `execute` 一次。

## 成本

成本幾乎全在 Cloud Run **Job**，而且由**執行次數**決定，不是由每次跑多久決定。Cloud Run Job 按 instance
的整個生命週期計費，**每次執行最少算 1 分鐘**（https://cloud.google.com/run/pricing ）：一次輪詢實際工作約
12 秒，帳單上是 60 秒。asia-east1 的單價是每 vCPU-秒 US$0.000018、每 GiB-秒 US$0.000002；免費額度是每月
240,000 vCPU-秒與 450,000 GiB-秒，**整個帳單帳戶共用**。1 vCPU 的 Job 一次執行用掉 60 vCPU-秒，所以免費額度
約等於每月 4,000 次執行（每天約 129 次），而且是本頁的 `rainyclock-dayoff-poll` 與會員服務的
`rainyclock-membership-deletion`（`weather-proxy/membership/MAINTENANCE.md`）**兩個排程 Job 合計**；手動
`jobs execute`、task 重試與 sandbox Job 的執行也算在同一份額度裡。512Mi 的記憶體一次 30 GiB-秒，先用完的是
vCPU 那一項。

- 2026 年 9 月帳單（實際數字）：Cloud Run 用量 US$5.64，免費額度折抵 US$4.62，實付 US$1.02，全部來自
  Cloud Run。本頁的排程 09-24 才開始，所以那還不是完整一個月。
- 舊頻率（兩個排程各每 5 分鐘，合計每天 576 次）：31 天 17,856 次、約 107 萬 vCPU-秒，扣掉免費額度後約
  US$15／月。這一節在 2026-10-02 之前寫的「每月約 US$0.50」漏算了 1 分鐘下限，是錯的。
- 現行頻率（本頁每 30 分鐘＝每天 48 次，會員刪除每天 2 次，合計 50 次）：31 天 1,550 次、約 93,000
  vCPU-秒，在 240,000 之內，Cloud Run Job 是 US$0／月，還剩約 2,400 次給手動執行、重試與 sandbox。

**之後要調高頻率的人必須重算這一段**：兩個排程 Job 的每天次數相加 × 當月天數 × 60 秒（執行超過 1 分鐘就用
實際秒數），對 240,000 vCPU-秒；超過的部分每 vCPU-秒 US$0.000018。例如只把本頁調回每 5 分鐘（每天 288＋2
次）約 US$5.4／月。改頻率時 `POLL_INTERVAL_MS`、`MAX_CACHE_AGE_MS`、告警視窗與 App 的新鮮度上限要一起改（§8）。

其餘項目都小到可以忽略：具名 Firestore 資料庫沒有免費額度，全專案四個資料庫合計約 US$0.10／月（本頁的部分是
每次 Job 讀寫幾份小文件，手機讀取被 5 秒快取吸收）；Secret Manager 免費 6 個啟用中的版本，第 7 個約
US$0.06／月；Cloud Scheduler 免費額度 3 個 job，目前用了 2 個（本頁與會員刪除）。Service 是 `min-instances 0`；
`min-instances 1`（約 US$5–8／月）只在真實警報期間 p95 延遲超過 3 秒時考慮。Sandbox 堆疊（`rainyclock-dayoff-sandbox`、
`rainyclock-dayoff-poll-sandbox`、同一資料庫的 `DAYOFF_NAMESPACE=dayoff_sandbox_v1`、`APNS_PRODUCTION=false`，
給 Xcode Debug 裝置用，見「Sandbox 堆疊」）沒有 Scheduler、`min-instances 0`，不用時幾乎零成本；每次手動執行
sandbox Job 同樣算 1 分鐘。

## 部署前在本機做的驗證

```sh
cd dayoff-service
npm test                                   # 100 通過，Emulator 那 7 個標 skip
npx firebase-tools emulators:start --only firestore --project demo-rc-dayoff &   # 需要 Java 21；或直接跑 ~/.cache/firebase/emulators/cloud-firestore-emulator-*.jar --host 127.0.0.1 --port 8686
FIRESTORE_EMULATOR_HOST=127.0.0.1:8686 npm test   # 107 通過；test/firestore.test.js 用 demo-rc-dayoff、dayoff-emulator、隨機 namespace
pkill -f cloud-firestore-emulator
```

Emulator 那一組跑的是真的 Firestore 交易：容量上限下的並行註冊、410 與重新註冊的競賽、並行回報
的排序、租約不在手上時提交失敗、兩個 execution 搶租約、兩個送出者搶同一個 claim、以及完整的
`runJob`（改變 → claim → 推播 done → 指標清空）。Emulator 每次交易衝突會印 `Transaction lock timeout`
警告，那是測試刻意製造的。

## 執行紀錄

### 2026-09-24 凌晨（Claude 執行，讀回值）

- Firestore：`projects/rainyclock/databases/dayoff-production`，FIRESTORE_NATIVE，asia-east1，
  DELETE_PROTECTION_ENABLED（`gcloud firestore databases create … --edition=standard --delete-protection`）。
- TTL：`expiresAt` 在 `devices`、`caps`、`broadcasts`、`retries` 四個 collection group 皆 ACTIVE。
- 索引豁免：`state.noticesJSON`、`caps.xml` 皆 0 個索引（`--disable-indexes`）。
- Secret 容器：`dayoff-ncdr-api-key`、`dayoff-apns-key`，user-managed，asia-east1，**都還沒有版本**。
- 映像：Cloud Build `065aed86-83ae-4f1b-acda-817bf0f5d251`，37 秒，SUCCESS，來源為 commit `d0e80ab`；
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:dabe3190a127fb5ac0c31af85cc5c1a862eb72ed6562650caebcb1835d472196`。
- 本機：`npm test` 100 過 7 略過；Firestore Emulator 1.22.0 ＋ Homebrew `openjdk@21` 107 全過。

### 2026-09-24 09:2x（擁有者執行 `deploy/iam.sh`，讀回值）

- 建立 `rainyclock-dayoff-service@`、`rainyclock-dayoff-job@`、`rainyclock-dayoff-scheduler@`。
- `roles/datastore.user` 條件 `resource.name=="projects/rainyclock/databases/dayoff-production"` 綁到
  service 與 job 兩個 SA（etag `BwZcMJgIpic=`、`BwZcMJhEZ2Y=`）；兩個 secret 的 `secretAccessor` 綁到 job SA。
- Scheduler 的 `run.invoker` 尚未綁（Job 還不存在，Job 建好後重跑腳本）。

### 2026-09-24 09:35（Claude 部署 service，讀回值）

- `gcloud run deploy rainyclock-dayoff`（§6 的參數，digest `sha256:dabe3190…`）→ revision
  `rainyclock-dayoff-00001-h5r`，URL `https://rainyclock-dayoff-510427696731.asia-east1.run.app`
  （`status.url` 另回 `https://rainyclock-dayoff-hclsjropwq-de.a.run.app`，兩者同一服務）。
- 前幾分鐘 `/health` 回 503 `storage_unavailable`：新 SA 的 IAM 還在傳播。約 5 分鐘後回
  503 `{"configured":false,"available":false,"state":"not_configured",…,"pushConfigured":true,"pushMode":"alert"}`，
  九個鍵完整。`DELETE /v1/devices` 帶垃圾 JSON → 400 `invalid_device_request`（body 有轉送、無轉址）。
- 教訓寫進程式：`10d9951` 起 store 在 SDK 失敗時記一筆 `storage_failure` 與 gRPC 狀態碼（不含訊息）。
  重建映像並以新 digest 重新部署，見下一條。

### 2026-09-24 09:40（Claude 重建並重新部署 service，讀回值）

- Cloud Build `43e2bed6-a679-4b25-bc93-7bf082d40dac`，40 秒，SUCCESS，來源 commit `10d9951`；
  **目前 service 與未來 Job 都要用這個 digest**：
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:dbe6fca534098277f2c9ce5f02520413cddaccbd70449a277620c0ed8c39aef5`。
- `gcloud run deploy rainyclock-dayoff --image=<上面 digest>` → revision `rainyclock-dayoff-00002-f6j`，100% 流量；
  `/health` 503 `not_configured`，九鍵完整。等第一次 Job 跑完才會變 200。

### 2026-09-24 11:24–11:27（Claude 執行 `deploy/deploy.sh`，`NCDR_SOURCE=open-data`、無 APNs，讀回值）

- 為什麼是 open-data：NCDR 會員註冊頁「僅受理公務、公司或學校信箱」，個人申請不到金鑰（`3c227c4`）。
- Cloud Build `120a877b-4a38-4995-adbc-37b18365a130`，35 秒，SUCCESS，來源 commit `3c227c4`；**現行 digest**
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:d4024db97dc0243b32b7a3f38985d29350616c3ec23b325e16d937ecb936349d`。
- service `rainyclock-dayoff` revision `rainyclock-dayoff-00003-x2l`，`PUSH_CONFIGURED=0`（無 APNs）。
- Job `rainyclock-dayoff-poll` 建立（`NCDR_SOURCE=open-data`，無 secret 掛載）。第一次執行
  `rainyclock-dayoff-poll-kzsx5`：摘要 `ok=true refreshed=true changed=true noticeCount=14 source=open-data
  warmup={status:200, revisionMatches:true}`，1,240 ms。之後 `/health` 200 `ready`；`/v1/suspensions`
  回 14 則 2026-08-22～08-24 的真實 DGPA 公告（`sourceUpdatedAt` 2026-08-24T10:29Z）；`/health/details`
  `source:"open-data"`、`storage:"firestore"`、`broadcast.state:"pending"`（沒有 dispatcher 就不送，指標保留）。
- 重疊證明：同時執行兩次 → `hq47r` `refreshed=true changed=false`、`px7vj` `skipped=lease_held`，兩者 exit 0。
- Scheduler `rainyclock-dayoff-poll` 建立，`*/5 * * * *` Asia/Taipei，ENABLED；**在擁有者重跑 `deploy/iam.sh`
  補 `run.invoker` 之前，整點觸發會被拒**。

### 2026-09-24 11:44（擁有者重跑 `deploy/iam.sh`，補 `run.invoker`；讀回值）

- `gcloud scheduler jobs run` 手動觸發 → execution `rainyclock-dayoff-poll-b5vmw` 成功；03:45Z 整點自動觸發 →
  `rainyclock-dayoff-poll-88db6` 成功；Scheduler `lastAttemptTime` 03:45:04Z、`status: {}`。兩次摘要
  `refreshed=true changed=false`。**從這一刻起每 5 分鐘自動輪詢。**

### 2026-09-24 11:58（擁有者加入 `dayoff-apns-key` 版本 1；Claude 重跑 `deploy/deploy.sh` 開推播，讀回值）

- 第一次重跑因腳本同時給 `--clear-env-vars` 與 `--set-env-vars` 而在 Job 更新失敗（service 已先升到
  `00004-2c2`）；修正腳本後重跑成功：service `rainyclock-dayoff-00005-xgg`（`PUSH_CONFIGURED=1`），
  Job 更新為掛載 `/secrets/apns/AuthKey.p8` 與 APNs 環境變數（Team、Key ID、topic、`APNS_PRODUCTION=true`、
  `APNS_PUSH_MODE=alert`），仍 `NCDR_SOURCE=open-data`、無 NCDR key。
- Job 啟動時讀取並解析 `.p8` 成功（金鑰格式無誤）。execution `rainyclock-dayoff-poll-5vz68`：
  `refreshed=true changed=false`，**broadcast 從 `pending` 走到 `done`**：`attempts=1 accepted=0 failed=0
  unregistered=0 retryPending=0`，因為目前沒有任何裝置登記（1.7.0 閘門關著）。`pendingBroadcastRevision`
  已清空。`/health` `pushConfigured:true pushMode:"alert"`。
- 尚未對真實裝置送過任何推播；第一次真機驗證要等 1.8.0 開閘、手機登記後，再看 `push_batch` 記錄。
  （2026-10-03 完成：App Store build 40 登記後 `push_batch accepted=1`，見 2026-10-03 15:18–15:23 的紀錄。）

### 2026-09-24 12:10–12:25（擁有者提供 email；Claude 建告警，讀回值）

- 記錄指標：`dayoff_job_runs`、`dayoff_job_failures`、`dayoff_broadcast_incomplete` 已建立（`gcloud logging metrics create`）。
- 本機 gcloud 沒裝 `beta`／`alpha` 元件，`gcloud beta monitoring channels` 與 `gcloud alpha monitoring policies` 都不可用；
  改走 Monitoring REST API（`curl` ＋ `gcloud auth print-access-token`）。`alerts/*.json` 是實際送出的內容，
  與 `alerts/*.yaml` 同義；YAML 已填入真實通道 ID。
- 通知通道 `projects/rainyclock/notificationChannels/10219649454523194367`（email，`shukaihu@icloud.com`，enabled）。
  **需要擁有者點 Google 寄來的驗證信**，未驗證前告警不會寄出。
- Policy：`…/alertPolicies/6544845589806021377` poll absent（15 分鐘無摘要）、`…/14647107143383542161`
  execution failed、`…/12166636093063786863` poll degraded。API 只接受 `COMPARISON_GT`／`LT`，
  「至少 3 次」改寫成「多於 2 次」。三個都 enabled。
- absence 告警的實測（暫停 Scheduler 20 分鐘看是否寄信）**尚未做**，要等通道驗證後執行。

### 2026-09-24 13:20–13:48（absence 告警實測，讀回值與擁有者回報）

- email 通道**不需要驗證**：API 回的 `verificationStatus` 未設定，官方文件定義為「該類型不需驗證」。
  先前「待驗證信」的說法有誤。
- 13:20:24 `gcloud scheduler jobs pause`。暫停前 13:20 那次排程剛好跑完，`dayoff_job_runs` 最後一個資料點
  05:22:23Z，之後沒有任何點。
- 13:43 另以 `notificationChannels/…:sendVerificationCode` 請 Google 寄一封測試碼信，單獨驗證送達。
- **擁有者回報兩封都收到**（`shukaihu@icloud.com`）：測試碼信，以及 `rainyclock-dayoff poll absent` 告警信。
  也就是「Scheduler 停了沒人知道」的保險端到端有效，iCloud 不擋 Google Monitoring 的信。
- 經驗值：absence 告警在最後資料點後約 20 分鐘寄達（15 分鐘條件＋5 分鐘對齊＋評估延遲）。
  暫停期間服務超過 15 分鐘沒更新，`/health` 轉為 `unavailable`（`stale_cache`），手機會拿到 503 並照響——符合設計。
- 13:48:32 恢復（ENABLED），補跑 `rainyclock-dayoff-poll-n784k` 成功，`/health` 回到 `ready`。
  注意：`sh` 在 `sleep` 期間收到 SIGTERM 不會立刻跑 trap，要連 `sleep` 一起結束。

**未執行**：真機推播驗證（§10，等 1.8.0 開閘；2026-10-03 已完成，見該日紀錄）。之後若要輪替 APNs 金鑰，帶新 Key ID 重跑
`deploy/deploy.sh`（§秘密處理與輪替）。Firestore deny-all rules 未用 firebase-tools 部署（本機未登入）；
服務帳號走 IAM，rules 只影響手機 SDK。

### 2026-10-02 18:27–18:31（Claude 依擁有者決定降低輪詢頻率，讀回值）

- 原因：9 月帳單 Cloud Run 用量 US$5.64、免費額度折抵 US$4.62、實付 US$1.02，全部來自 Cloud Run。Job 每次
  執行最少計費 1 分鐘，兩個排程各每 5 分鐘（合計每天 576 次）在完整的 10 月會是約 US$15；「成本」一節原本的
  「每月約 US$0.50」漏算了這個下限，已改寫。
- Scheduler `rainyclock-dayoff-poll`：`5,35 * * * *` Asia/Taipei（原 `*/5 * * * *`），ENABLED，每天 48 次。
  選 5 分與 35 分而不是 0 分與 30 分：之前 9 天僅有的兩次 `upstream_rate_limited` 都在整點（2026-09-29 15:00
  與 20:00）。最後一次 5 分鐘排程是 18:25，新排程的第一次是 18:35。
- Job `rainyclock-dayoff-poll`：`POLL_INTERVAL_MS=1800000`（原 `300000`）。映像 digest 不變
  （`sha256:d4024db9…`），沒有重新部署程式。
- Service `rainyclock-dayoff`：`MAX_CACHE_AGE_MS=3600000`（原 `900000`）→ revision `rainyclock-dayoff-00006-j42`，
  100% 流量，同一個 digest，`/health` 200。快照超過 1 小時（連續兩次輪詢沒成功）才回 503 `stale_cache`，
  原本是 15 分鐘。
- Sandbox service `rainyclock-dayoff-sandbox`：同樣 `MAX_CACHE_AGE_MS=3600000`（revision
  `rainyclock-dayoff-sandbox-00002-4c8`），與正式保持一致；仍然沒有 Scheduler，最後一次手動執行 1 小時後
  （原 15 分鐘）回 503 `stale_cache`。
- 告警，以 Monitoring REST API `PATCH` 送出 `alerts/absence.json` 與 `alerts/broadcast-incomplete.json`：
  `…/alertPolicies/6544845589806021377` poll absent 的 `conditionAbsent.duration` 7200s（原 900s）、
  `alignmentPeriod` 先改成 1800s，審查指出那樣信要到約 2.5 小時才寄（條件加對齊），19:08 前後再 `PATCH` 回 300s，
  條件名 `no dayoff_job summary in 2 hours`——擁有者要的是兩小時沒反應才寄信，也就是連續錯過四次輪詢，
  預期在最後一次摘要後 2 小時又幾分鐘寄達。`…/alertPolicies/12166636093063786863` poll degraded 兩個條件的
  `alignmentPeriod` 7200s（原 1200s），仍是「多於 2 次」（連續四次輪詢裡有三次），條件名改成 `… in 2 hours`。
  第三個 policy（execution failed，600s 視窗）與頻率無關，沒有動。
- 程式預設值（`POLL_INTERVAL_MS` 300000、`MAX_CACHE_AGE_MS` 900000）刻意沒改，也沒有重建映像：正式與 sandbox
  都明設這兩個值，`deploy/deploy.sh`、`deploy/sandbox.sh` 與 `alerts/` 下 absence、broadcast-incomplete 的
  YAML／JSON 已改成同樣的數字（sandbox Job 的 `POLL_INTERVAL_MS=60000` 不動）。
- 成本：同時把 `rainyclock-membership-deletion` 的排程降為每天 2 次（細節在
  `weather-proxy/membership/MAINTENANCE.md`）。合計每天 48＋2＝50 次 Job 執行，31 天約 93,000 vCPU-秒，在免費的
  240,000 之內，這個頻率下 Cloud Run Job 是 US$0／月。
- 影響：公告出現在來源後，最慢約 30 分鐘才推到手機（原約 5 分鐘）。一次輪詢失敗後 service 立刻回 503
  直到下一次成功，這段時間通常約 30 分鐘（原 5 分鐘；長時間故障時見運行手冊的退避說明）；改頻率前 9 天約 2,400 次執行裡來源失敗 3 次。APNs
  429／5xx 的重送與 3 次嘗試上限每個 tick 前進一步，現在每步相隔 30 分鐘。App 自己的規則只改了新鮮度上限
  （15 分鐘 → 1 小時，1.8.0 build 40，記在 `docs/STATUS-IOS.md`）：鬧鐘略過仍接受 18 小時內的 Feed，5 分鐘的
  重抓節流不變。

- 新排程的前兩次自動輪詢（讀回）：`rainyclock-dayoff-poll-d46j6` 18:35:00 建立、18:35:13 摘要 `ok=true
  refreshed=true changed=false noticeCount=14`；`rainyclock-dayoff-poll-kczt5` 19:05:05 建立、19:05:13 摘要
  `ok=true refreshed=true changed=false`。18:30 與 18:40 沒有執行。18:56 讀 `/health` 為 `ready`（資料已 21 分鐘，
  舊的 15 分鐘上限下會是 503），`nextAttemptAt` 落在 30 分鐘後。

**未執行**：absence 告警在 2 小時視窗下的端到端實測（暫停 Scheduler 超過 2 小時看是否寄信）沒有重做；
09-24 的實測是 15 分鐘視窗。退避上限等於排程間隔的問題（運行手冊 `upstream_*` 一列）要等下次重建映像時把上限
壓到排程間隔以下，這次沒有動程式。

### 2026-10-03 15:18–15:23（1.8.0 上架後，擁有者手機首次對正式服務登記與推播實測，讀回值）

- 背景：1.8.0（40）審核通過、擁有者手動發佈，約 14:36 在 App Store 公開。擁有者手機（iOS 27，App Store
  build 40）的會員 session 先因裝置金鑰問題持續 401、臨時放假開關停用，15:18:37 恢復後 App 才開始對本服務
  登記（經過與處置在 `weather-proxy/membership/MAINTENANCE.md`「裝置金鑰斷言失敗與處理 — 2026-10-03」）。
- 正式 service `rainyclock-dayoff` 的請求（Cloud Logging，user agent `RainyClock/40`）：15:18:42
  `GET /v1/suspensions` 200 與 `POST /v1/devices` 201；15:18:45 `POST /v1/devices/sync-receipt` 200；
  15:19:07 `POST /v1/devices` 200（續約）。`dayoff-production` 的 `devices` 數量 0 → 1。**這是第一次有正式簽章的
  build 對正式堆疊登記**；09-24 11:58 的 broadcast `accepted=0` 就是因為當時沒有任何裝置。
- 推播實測（§10「強制一次 revision 改變」）：Claude 的寫入被 auto-mode 分類器擋下，兩道指令都由擁有者在自己的
  終端機執行：Firestore `PATCH state/current.revision = "push-test-2026-10-03-owner-device"`（200），再
  `gcloud run jobs execute rainyclock-dayoff-poll --wait` → execution `rainyclock-dayoff-poll-zpwlk`。
- Job log 07:22:34–35Z：`source_checked changed=true noticeCount=14`；`dayoff_warmup status=200 revisionMatches=true`；
  `push_batch accepted=1 failed=0 unregistered=0 retryPending=0 attempts=1 state=done`，revision `63655ce2…`；
  摘要 `ok=true refreshed=true changed=true durationMs=1913`。log 裡只有**一個** `push_batch`。Job 已把
  `state/current.revision` 寫回真實的 `63655ce2…`，測試字串不必還原。
- 07:22:36Z `GET /v1/suspensions` 200，user agent `RainyClockDayOffNotification/40`：通知服務擴充功能在推播送出後
  0.4 秒抓了 Feed。`/health/details` 回到 `ready`、revision `63655ce2…`、broadcast state `done`。
- 擁有者 15:23 鎖定畫面截圖：橫幅「Work/school closure update — Not for your districts; the alarm rings as usual.」
  （安靜的通用文字：Feed 的 14 則裡沒有擁有者行政區的停班停課），鎖定畫面矩形小工具
  「Tomorrow · S… Skipped — Tomorrow is a weekend day」。
- 結論：§10 的真機推播驗證項目完成。production APNs 憑證、發行簽章的 `aps-environment=production` 配
  `APNS_PRODUCTION=true`、以及通知擴充功能的改寫都已在正式堆疊驗證；09-24 11:58「尚未對真實裝置送過任何推播」
  與 09-24 13:48「未執行：真機推播驗證」自此關閉，「由擁有者親手完成」第 3 點的 `APNS_PRODUCTION`／
  `aps-environment` 不確定性也解除。

**未讀回**：這次之後下一個排程 execution（15:35）的摘要是否 `changed:false`、`broadcast:null`（§10 下一項）；
真實公告（而不是改 revision 字串）觸發的推播，仍要等颱風期間才有。

### 更早
第一次執行時，在這裡逐條記錄：日期、指令、讀回的結果（資料庫設定、SA 與 IAM 條件、secret 版本號、
build id 與映像 digest、service URL、第一次 execution 名稱與摘要、重疊測試的兩份摘要、Scheduler
派送與 execution、告警建立與 absence 實測、真機推播證據），以及本機證據檔的路徑。

### 2026-10-05 15:35 起：NCDR 免金鑰的停班停課 feed 改為要求登入，輪詢全部 `invalid_source_xml`（事件紀錄，Claude 10-06 診斷）

- 症狀：Google Cloud Alerting「rainyclock-dayoff poll degraded」10-05 17:08（UTC 09:08）寄信；從 10-05 15:35（最後一次
  `ok:true`）之後每一個 tick 都是 `ok:false`、`errorCode:"invalid_source_xml"`、`source:"open-data"`，交替 `skipped:"backoff"`；
  `/health/details` 是 `state:"unavailable"`、`lastSuccessAt 2026-10-05T07:35:19Z`、revision 不變、`noticeCount 14`。
  Job 本身沒有錯，`broadcast` 仍是 10-03 的 `done`。
- 根因：`https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx?AlertType=33`（data.gov.tw 資料集 20457 登記的網址，
  `NCDR_SOURCE=open-data` 就是打它）現在回 HTTP 200、`application/xml`、73 bytes：
  `<WarningMessage><Warning>請先登入會員。</Warning></WarningMessage>`。根元素不是 `feed`，`parseAtom` 的 `xmlRoot`
  正確地擲出 `invalid_source_xml`。`JSONAtomFeed.ashx?AlertType=33` 同樣回 `{"Warning":"請先登入會員。"}`。這就是
  `service.js` 註解裡「NCDR 宣布 2026-03-31 退役、9-24 還活著」的那個退役，10-05 下午生效。
- 還開著、不用登入的（10-06 18:2x 實測）：①不帶 `AlertType` 的 `RssAtomFeed.ashx`（所有單位的 CAP 合集，236 KB、308 筆，
  目前全是水利署／氣象署；停班停課的 entry id 是 `dgpa.gov.tw_workSchlClos_*`，有公告時應該也會在裡面，但現在無法驗證）；
  ②`Capstorage/...cap` 檔案本身（200，`application/xml`）；③`server/v1/Alerts/Search/history?alertTypeId=33&sentdate=<D-1>&effective=<D>`
  （`DAYOFF-SPEC.md` §2.2 的歷史查詢 API）：`sentdate=2026-08-23&effective=2026-08-24` 回 `total>0`，每列有 `filePath`
  指到 `Capstorage/DGPA/2026/workschoolclose_cap/dgpa.gov.tw_workSchlClos_…cap`；同站 429「限制存取間隔時間為3秒」照舊。
  會員 API（`webapi/RssAtomFeed.ashx?AlertType=33&apikey=…`，`NCDR_SOURCE=member`）程式早就支援，但 `dayoff-ncdr-api-key`
  至今沒有版本——擁有者個人信箱申請不到會員。
- 對使用者的影響：service 對手機回 503 `stale_cache`／`invalid_source_xml`，App 照原本的保守規則走——鬧鐘照常響、不會
  把舊公告當今天的；設定 › 行事曆那一列會顯示來源不可用。沒有颱風的這段時間，差別只有「無法得知新公告」。
  degraded 告警會一直響到修好為止，absence 告警不會（摘要行還在）。
- 處置：擁有者 10-06 選了「改打歷史查詢 API」（`NCDR_SOURCE=history`），同日部署，見下一則紀錄。

### 2026-10-06 18:5x–19:00（Claude 執行，`NCDR_SOURCE=history` 上線，讀回值）

- 程式：`1501064`「Day-off: a third source, NCDR's keyless history search」——`src/service.js` 新來源 `history`
  （最近三個台灣日各自送出的公告、每頁 10 筆、請求間隔 3 秒、同頁 429 重試兩次、整輪上限 300 秒、單日超過 200 則拒收
  `too_many_notices`；**不看 `expires`**，因為它是公告日的結束而不是停班日的；只在有新公告或重發時才排推播，視窗滾掉舊公告
  只換 revision 不推），`src/parser.js` 的 `parseHistoryPage` 與 `source_login_required`，`deploy/deploy.sh` 接受 `history`。
  本機 `npm test` 131 項 122 過 9 略過；用真 API 跑 8/24 傍晚、8/25 00:05 與今天三個時點：5、10、0 則，CAP 全部抓到且驗證通過。
  三位獨立審查（正確性／安全／維運）的發現都已處理：原本照 `expires` 丟公告會在停班當天 00:05 把「明天停班」丟掉（高）、
  視窗要三天才涵蓋 App 的兩天提前規則（中）、午夜滾動不該推播（中）、429 要在同一輪重試（中）、分頁以實收筆數為準、
  暫停要看 signal 已中止、XML 的登入牆也要報 `source_login_required`、失敗 log 帶 `phase`／`window`／`page`／`requests`。
- 實測 CAP 檔不受 3 秒限制：歷史查詢後 0.1 秒內連抓兩個 `Capstorage/…cap` 都 200，所以 CAP 仍 4 路並行、不加間隔。
- 映像：Cloud Build `76d888d4-61c0-4590-ab4e-ad7aa4d2a841`，37 秒，SUCCESS，標籤 `1501064`，
  `rainyclock-dayoff@sha256:cbc68116bc271156bdf4e06f1febda9b2c234ba77e87fb783893299580eabcac`。
- `IMAGE=<digest> NCDR_SOURCE=history APNS_KEY_ID=H9SMW8923R APNS_PRODUCTION=true sh dayoff-service/deploy/deploy.sh`：
  service `rainyclock-dayoff-00007-zht`（部署當下 `/health` 503 是舊快取已過期，正常）；Job 更新（`NCDR_SOURCE=history`、
  其餘 18 個環境變數與前一版逐一相同、`/secrets/apns` 掛載照舊；template 裡多留了一個沒掛載的舊 volume
  `dayoff-apns-key-wim-goc`，是 `--set-secrets` 的副作用，無害）；第一次執行 `rainyclock-dayoff-poll-c9tvj` 成功：
  `ok:true`、`source:"history"`、`refreshed:true`、`changed:true`（從 8 月的 14 則變成空集合，`noticeCount 0`）、
  `source_checked requests:3`（三個日期視窗各一頁）、6.4 秒；`/health` 200、`/health/details` `state:"ready"`、
  `errorCode:null`、`lastSuccessAt 2026-10-06T10:58:06Z`、`broadcast:null`（集合變小不排推播，照設計）。
  service 的環境變數前後無差異，只換映像。Scheduler 已存在未動（`5,35 * * * *` Asia/Taipei）。
- 告警：degraded policy 看的是 2 小時內的 `ok=false` 次數，10-05 17:08 開始響的事件會在連續兩小時成功後自己結束。
- 回退：`IMAGE=…@sha256:d4024db97dc0… NCDR_SOURCE=open-data APNS_KEY_ID=H9SMW8923R APNS_PRODUCTION=true sh dayoff-service/deploy/deploy.sh`
  （會回到被擋的來源，只有 NCDR 恢復免金鑰 feed 時才有意義）。

