# 語氣分類模型更新 — 2026-09-16

將每句鬧鐘文字的語氣分類改為 `gemini-3.1-flash-lite`，使用 Vertex AI 美國多區域 `us`。
Cloud Run 服務仍位於台灣 `asia-east1`。語音合成繼續使用原本的 Cloud Text-to-Speech
`gemini-2.5-flash-tts`，六個角色的聲音、提示詞與音訊格式沒有更換。

## 實作

- `us`／`eu` 使用 `aiplatform.{location}.rep.googleapis.com`；`global` 使用
  `aiplatform.googleapis.com`；原本一般區域的網址也保留，供明確指定模型／地區回退。
- REST 請求使用 `generationConfig.thinkingConfig.thinkingLevel: "MINIMAL"`。
  只有已核對支援的 3.1／3.5 Flash-Lite 明確帶入此值，其他模型沿用各自預設。
- 保留 JSON enum、句數 schema、8 秒分類請求期限與逐句 `neutral` 備援。
  多個輸出文字片段會接起來解析，忽略 `thought: true` 片段。
- `annotation_fallback` 紀錄失敗類別、模型、地區、句數與狀態碼／備援句數。
  不寫入使用者文字、token、模型輸出或可能含原文的上游錯誤內容。
- 單次分類無工具呼叫或多輪對話，不新增 thought-signature 保存機制。

## 驗證

- 離線單元測試 **73／73 通過**，包含新增 27 個分類端點、請求格式、解析、回退與日誌測試。
  [完整測試紀錄](unit-tests.log)
- 以此 Google Cloud 專案實際呼叫新模型：繁中／英文 × 六個角色，**12／12 分類成功**，
  全部回傳符合格式的語氣，沒有 fallback。[分類測試結果](annotation-results.json)
- 測試句子均為人工編寫的示範文字，並非真實使用者的鬧鐘內容。
- 測試 revision 以原 Cloud Run 服務帳號完成 **12／12 語音生成**（繁中／英文 × 六角色），
  檢查 HTTP 200、語氣標籤、24 kHz／mono／16-bit PCM、非靜音與 10 秒長度上限。
  [語音測試結果](speech-results.json)。這是生成與音訊格式驗證；主觀聽感可用下方檔案確認。

## 正式部署

- 2026-09-16 19:20 Asia/Taipei 已驗證 `rainyclock-weather-proxy-00012-win` 承接 **100%** 流量。
  先部署 0% 流量的 tagged revision，通過上述測試後切換，並移除測試 tag。
- 正式 App 使用的固定 URL 再測 `/v1/tts` 與 `/v1/weather` 均回傳 **200**，天氣為 25 小時資料。
  [正式驗證](production-smoke.json)、[部署設定驗證](deployment.json)。
- 原有環境變數／Secret Manager 參照、service account、CPU／記憶體設定均保留，
  新增明確設定 `VERTEX_LOCATION=us`、`VERTEX_ANNOTATE_MODEL=gemini-3.1-flash-lite`。
- 截至驗收查詢，新 revision 沒有 `annotation_fallback` 紀錄。[查詢結果](fallback-logs.json)
- App 不需更新；下次重新生成語音即使用新版分類。已存好的音檔不會自動重製。
- 若需回退服務流量：`gcloud run services update-traffic rainyclock-weather-proxy --project rainyclock --region asia-east1 --to-revisions rainyclock-weather-proxy-00011-vj2=100`。
  若改用新版程式配舊模型，請同時指定 `VERTEX_ANNOTATE_MODEL=gemini-2.5-flash` 與 `VERTEX_LOCATION=us-central1`。
- 本次只改分類後端，未更換 TTS 模型、部署停班停課服務、提交 Git 或上傳 App Store。

## 試聽檔

示範文字：繁中「早安，該起床囉。記得帶傘！」；英文「Good morning. Bring an umbrella!」。

| 角色 | 繁中 | 英文 |
| --- | --- | --- |
| steady | [播放](zh-Hant-steady.wav) | [播放](en-steady.wav) |
| bright | [播放](zh-Hant-bright.wav) | [播放](en-bright.wav) |
| gentle | [播放](zh-Hant-gentle.wav) | [播放](en-gentle.wav) |
| buddy | [播放](zh-Hant-buddy.wav) | [播放](en-buddy.wav) |
| mom | [播放](zh-Hant-mom.wav) | [播放](en-mom.wav) |
| sergeant | [播放](zh-Hant-sergeant.wav) | [播放](en-sergeant.wav) |

[下載全部試聽檔與驗證結果](voice-samples.zip)

## 官方依據

- [3.1 Flash-Lite 型號與支援地區](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-1-flash-lite)
- [區域／多區域端點](https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/locations)
- [REST generationConfig schema](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/models/inference)
- [模型 thinking 設定](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/thinking)
- [Thought signatures](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/thinking/thought-signatures)
