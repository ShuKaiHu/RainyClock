# Product Decisions / 產品決策

## 1.8.0「明天」widget 的四項決定 — 2026-09-24（使用者決定 D-A～D-D，已實作於 `ios/widget`）

- **D-A WeatherKit 標示。** 只有 medium 顯示天氣資料（住家／公司天氣、降雨 %、依天氣畫的天空），
  並帶 Apple 的  Weather 組合標記與法律頁連結。依據 Apple〈Apple Weather and third-party
  attribution〉(developer.apple.com/weatherkit/get-started)：顯示 Apple 天氣資料就必須清楚顯示
   Weather 商標與其他資料來源的法律連結；5.2.5 有 widget 缺標記被退的前例。標記圖由 App 在
  已經連 WeatherKit 的時候（卡片的 `WeatherAttributionView`、背景更新）下載
  `combinedMarkLightURL`／`DarkURL` 存進 App Group，widget 畫它；還沒下載前畫文字「 Weather」。
  medium 的天氣欄是 widget `Link`（`rainyclock://weather-attribution`），App 收到後開
  `legalPageURL`。**其他尺寸**（small、StandBy、長方形、圓形、inline）只顯示鬧鐘決定：
  因雨提早 N 分鐘（不帶路線降雨 %）、一般日「照常響鈴」、small 天空只在因雨提早時下雨、其他時候
  晴天（不畫多雲、不跟預報）、StandBy 不再有天氣符號。天氣「過期／失敗／尚無預報」是資料新舊，
  保留。**殘餘風險：** Apple 對「value-added」（由天氣資料轉換的產品）另要求標註  Weather 並
  註明資料已修改；「因雨提早」是否算此類由使用者判斷，目前照 D-A 不在非 medium 尺寸加標記。
- **D-B 過期。** 背景更新（BGTask）在發布 widget 前也抓明天天氣（`refreshTomorrowWeatherIfNeeded`，
  只在前 15 秒內開始、會被逾時取消、不登記也不改鬧鐘）。**widget 只在天氣超過 3 小時才警告過期**；
  卡片維持 30 分鐘。刻意不同：widget 整天掛在畫面上又不能自己更新，卡片是點開才看且會自己更新。
  鬧鐘決定（`TomorrowAlarmStatus.resolve`）仍用 30 分鐘，沒有改。
- **D-C 午夜到響鈴前顯示「今天」。** 從當地午夜到今天的鬧鐘響（略過的日子到原本時間），widget
  所有尺寸顯示**今天**的鬧鐘與原因（例：今天 上午6:40 因雨提早 30 分鐘），響過之後才換「明天」。
  顯示的是 AlarmKit 實際會響的已登記時間，今天的項目也在那個時間結束；只有午夜後 30 分鐘內預報
  仍新鮮又和登記不同時，才和卡片一樣顯示預報的決定並標「鬧鐘設定尚未更新完成」。
  snapshot 事先算好這些項目，App 不用醒著。**卡片不變**，整天都講明天：在 App 裡看的是要改什麼，
  今天的決定已經登記了。今天的項目不顯示天氣警告（App 只抓明天的預報，今天的無從更新；而且那些
  文字寫著「明天」）。
- **D-D 響鈴後沿用的提早。** 週鬧鐘在提早響過之後，隔天仍會在同一個提早時間響；顯示這個時間
  （真的會響），但在隔天自己的預報決定之前**不說「因雨提早」**，改成「等待明天預報」（今天的項目為
  「等待今天預報」）。卡片同規則。用同一天的預報決定、只是預報已過期的提早，仍說因雨提早。

## 颱風／臨時放假改定 1.8.0 — 2026-09-24

- 使用者決定：颱風與天災臨時放假的目標版本由 **1.7.1 改為 1.8.0**；1.7.1 保留給其他工作。
- 功能範圍、權益未定（買斷是否包含）與已部署的 dayoff-service 都不變，只改版本定位。
- 本檔與 `STATUS-IOS.md` 較早的紀錄保留當時寫的「1.7.1」；凡指這項功能的，都應讀成 1.8.0。
  備忘改名為 [1.8.0 deferred disaster](1.8.0-DEFERRED-DISASTER.md)。

## 舊會員 AI 次數遷移 — 2026-09-21（已批准）

- 使用者選定：**舊會員固定補發 1 次；舊廣告餘額保留待核對**。
- 後端依 Apple 驗證身分判定遷移資格，一個會員只領一次；手機申報數量不決定補發量。
- 已有舊會員待核對紀錄可安全補發一次。跨装置並行、刪除再建立及重送申報不再補發。
- 舊廣告申報保留，不直接變成可花用額度；新會員初始一次、付費共用每日一次不變。

## 會員方案頁順序與管理入口 — 2026-09-21

- 方案卡改為月訂閱在前、買斷在後；這是畫面排序，不改買斷權益優先的規則。
- 月訂閱英文標題為 **Monthly subscription**。恢復購買是正式功能，與同步、管理訂閱及
  刪除會員一起收進右上角會員管理選單，不再佔用底下整張操作卡。
- 有效訂閱顯示效期及自動續訂狀態；點續訂列開 Apple 訂閱管理，不提供未經 Apple 處理的
  本機續訂開關。Sandbox 效期包含時間，方便測加速續訂。
- 使用者要求退回剛購買的沙盒買斷，以測月訂閱。採 Apple 的測試退款表單＋已驗證退款
  通知撤權，入口僅 Debug Sandbox 顯示；不把清空測試歷史誤稱為退款成功。

## 買斷包含日曆並優先顯示 — 2026-09-21（最新權益）

使用者最新指定月訂閱與買斷都包含「移除 banner＋日曆」。買斷取得這些當前權益的永久
使用資格，會員層級高於月訂閱；此決定取代下方歷史「買斷不含日曆」規則。

| 項目 | 月訂閱 | 買斷 |
| --- | --- | --- |
| 移除 banner、日曆 | 訂閱有效期間 | 買斷有效即持續提供 |
| 每日免看廣告 AI 生成 | 1 次 | 1 次 |
| 額外 AI 生成 | 每次需完成 1 次獎勵廣告 | 同左 |
| 兩者同時持有 | 顯示買斷會員；共用每日 1 次，保留 Apple 訂閱實際狀態及管理入口 | 同左 |

- 使用者另行確認 AI 規則維持不變：當地午夜更新、未用不累積；免費仍初始 1 次，非每日。
  買斷＋訂閱不能疊加成每日 2 次，既有已存音檔的播放不扣次數。
- 已有有效買斷時，不再允許重複購買月訂閱。若原本已有 Apple 訂閱，繼續呈現真實效期／
  續訂狀態與「管理訂閱」入口，由使用者管理；App 不自動取消、退款或宣稱已取消。
- 訂閱到期仍有有效買斷時，日曆也持續可用，不降回基本規則；只有確認已沒有日曆權益時，
  才依原安全重排規則銜接，保留設定及既有排程。買斷退款／撤銷仍依 Apple 驗證狀態。
- 定價保持下表，年方案仍不販售。颱風臨時放假仍延至 1.7.1；本次不決定下一版
  該功能是否納入買斷，也不把「永久」解讀成尚未承諾的所有未來功能。
- 本次新權益已更新獨立 Sandbox（`00004-kkd`），ASC 買斷中英說明也已保存／讀回；
  沒有送審、發布或部署正式會員。測試與實際證據見 [iOS Status](STATUS-IOS.md) 與
  [測試環境紀錄](MEMBERSHIP-STAGING.md)，真機登入／購買仍待驗收。

## iOS 定價與方案精簡 — 2026-09-21

使用者最新指定只提供「月訂閱」與「非消耗型買斷」，不再提供年訂閱優惠方案。
此決定取代下方 2026-09-16 的三方案價格，以及 2026-09-17 暫定的台灣年費／買斷價格。

| 商店 | 月訂閱 | 買斷（一次付款） |
| --- | --- | --- |
| 美國 | US$1／月 | US$10 |
| 台灣 | NT$10／月 | NT$100 |

- 台灣價格為獨立指定，不採美國價格的自動換算值。其他商店價格仍未決定；App 持續顯示
  StoreKit 回傳的商店本地價格，不硬寫美元或台幣金額。
- 最新權益已由同日後續決定更新：月訂閱與買斷都包含移除 banner、日曆及每日一次免看廣告
  AI 生成；買斷優先顯示，永久持有當前權益。額外生成仍需一次獎勵廣告。
  颱風／天災臨時放假仍延至 1.7.1，不加入 1.7.0 對外文案。
- 不再將年訂閱列為可購買方案；既有年方案識別碼與已驗證交易不可因停止販售而直接
  當作退款或到期，仍須遵守 Apple 實際交易狀態及原有安全重排規則。
- 9/21 已在 ASC 保存並重讀核對上述價格；月訂閱與買斷均只供應美國＋台灣共 2 地區，
  年方案已停止銷售、0 地區。未來新地區自動供應 OFF。買斷改美國基準 US$10 後，
  Apple 重算其他地區自動價，再將台灣手動固定 NT$100；未供應地區的自動價格
  不是已批准售價。詳見 [測試環境紀錄](MEMBERSHIP-STAGING.md)。
  正式送審、發布與會員收費啟用仍是另外的步驟。
- 9/21 使用者最新確認及附圖兩列資料證實台灣、美國 Sandbox 帳號皆已建立；
  頁面總數與兩列不一致，不以總數否定建立完成。手機登入、商品讀取、購買與後端
  認回仍待驗收，不記錄測試憑證。帳號盤點中間狀態保留於 staging 歷史。

## iOS 美國限定 Sandbox 商品設定 — 2026-09-16（歷史，價格已被上方決策取代）

以下記錄當日實際設定，不能當作目前的方案目錄。

- 使用者明確批准：「先只開美國供 Sandbox 測試；其他地區不開放，對應價仍待確認」。
  已在 ASC 儲存並重讀核對月訂閱 US$1、年訂閱 US$10、非消耗型買斷 US$5；
  三個商品均為 USA only，未來新地區自動開放 OFF。
- 月／年權益相同，同屬 `RainyClock Plus` 群組且同為 level 1。年方案為預付 1 年；
  未配置「12 個月承諾、逐月付款」。家庭共享仍關閉。
- Apple 依美國基準產生的非美國對應價不是已批准的正式售價，其他地區不可售。
  本次批准範圍是 Sandbox 測試準備；沒有送審、發布或開放正式收費，正式上市價格與地區
  仍需另行確認。英文／繁中六筆商品與兩筆群組本地化已保存；審查截圖及真機驗收仍待完成。
- 獨立 Sandbox 後端已啟用並通過 Apple TEST 通知；真機商品讀取／購買、App Attest、
  LevelPlay 與 AI 端到端當時仍未測；Sandbox 帳號已於 9/17 由使用者提供建立完成截圖。
  正式 weather 服務與已封存 1.7.0（29）的空白會員 URL 不變，未修改 Android。
  實際商品 ID、文案與驗證證據見 [會員測試環境](MEMBERSHIP-STAGING.md)。

## 免費初始一次與兩種鈴聲 — 2026-09-16（最新）

- 使用者將免費方案的初始 AI 額度從 3 次改為 **1 次**，不是每日重置；
  已用計數、已獲廣告獎勵保留。付費方案仍每日一次，兩種鈴聲共用生成次數。
- 「提早響鈴」與「原定時間響鈴」可各選音色或 AI 人聲；舊資料兩者沿用原鈴聲。
  依實際註冊時間是否提早選用聲音，日曆逐日判斷；稍後提醒沿用該次聲音。
- 試聽、播放、重用已存 AI 音檔不扣次。新的 AI 生成成功儲存後才切換對應鈴聲。
  保留舊音檔，避免影響仍在響鈴／稍後提醒或已排程的鬧鐘。

## 1.7.0／1.7.1 發布範圍調整 — 2026-09-16

- 使用者決定 1.7.0 暫不公開颱風／天災臨時放假；移除對外資訊及入口，執行層停用，
  原始設定、程式、地圖與服務保留給 1.7.1。此決定優先於下方較早方案中的颱風權益。
- 當時 1.7.0 訂閱文案只列 banner、日曆及每日 AI，買斷未含日曆；後者已由 9/21 最新權益
  決策取代。臨時放假延後決定保留，不由本次日曆權益更動推論其買斷資格。
  會員服務尚未正式啟用，不因本次真機安裝而開放購買。
- 美國來源改為可選，以 OPM 常態聯邦假日及標準補假規則離線計算；不包含各州、
  學校、公司、輪班或一次性行政放假，可使用原有手動日期調整。
- 保留備忘與未發布隱私草稿：[1.8.0 deferred disaster](1.8.0-DEFERRED-DISASTER.md)（原 1.7.1）。

## iOS monetization decision — 2026-09-16（歷史設計）

### 使用者確認的方案

本節保留 9/16 當時的決策；價格、年方案及買斷不含日曆已由 9/21 決策取代，颱風功能另延至 1.7.1。
當時的決策取代較早的「每月 10 次 AI」與「暫不討論天災」方案。當時目標價格為 US$1／月、US$10／年、US$5 買斷，取代先前的
NT$10／月、NT$100／年、NT$50 買斷；其他權益沿用。當時已加入本機／測試環境實作；
後續獨立 Sandbox 部署與美國限定商品設定見上方最新決策，正式付費商品仍未上架。

| 權益 | 月訂閱 | 年訂閱 | 買斷 |
| --- | --- | --- | --- |
| 9/16 當時美元目標價（已取代） | US$1.00／月 | US$10.00／年 | US$5.00，一次付費 |
| 移除 banner 廣告 | 訂閱有效期間 | 訂閱有效期間 | 包含 |
| 日曆功能（國定假日、手動日期響／不響） | 包含 | 包含 | 不包含 |
| 颱風臨時放假功能 | 包含 | 包含 | 不包含 |
| 每日免看廣告生成 AI 鈴聲 | 1 次 | 1 次 | 1 次 |
| 當日超過內含 AI 次數 | 每多 1 次，完成 1 次獎勵廣告；或等隔天 | 同左 | 同左 |

- 對外用語是「移除 banner 廣告」，不能宣稱「完全無廣告」；額外 AI 生成仍可自願看
  rewarded ad。內含的每日 1 次不需要看廣告。AI 次數指生成，不是播放已儲存的鈴聲。
- 月訂閱與年訂閱享有相同權益。買斷不解鎖日曆或颱風臨時放假。
- 使用者最新將免費方案改為初始 1 次加獎勵廣告（非每日）；付費方案仍每日 1 次。
- 颱風臨時放假重新列入訂閱範圍；既有官方公告來源、資料驗證與手機完成排程的契約
  仍適用。列為付費功能不代表正式後端已部署或背景更新保證送達。
- 使用者於 2026-09-16 確認依討論方案繼續：第一版採免註冊會員，以可驗證的 Apple
  資料對應內部會員，透過現有 Google Cloud Run 後端讀寫 Cloud Firestore Standard
  資料庫，建議與後端同在台灣 asia-east1。付款使用 StoreKit，不建立信用卡表單。
  後續已要求直接實作，會員／Apple 驗證／FireStore 額度／恢復購買已加入程式，
  預設開關保持關閉，正式端尚未建立雲端資源、部署或啟用收費。舊版本機 quota
  不代表跨裝置額度，安全遷移仍是開放前置條件。
  執行流程與付款說明見 [Membership and payments](MEMBERSHIP-AND-PAYMENTS.md)。

### 美國價格級距查核 — 2026-09-16

- Apple 官方 USD 價格表明列 X.00 整數美元慣例，支援 US$1.00、US$5.00、US$10.00。
  不必改成 US$0.99／US$4.99／US$9.99；目前自動續訂及一般 App 內購買定價說明
  均提供預設最多 800 個價格級距。這是當時的可行性查核；後續已建立並核對商品測試價，見上方決策。
- 美國售價以美元設定；其他商店使用當地幣別與價格級距。建立商品時可採 Apple 按
  匯率和稅費產生的對應價，或手動指定。台灣價格在此查核當時尚未選定；9/21 已獨立指定月 NT$10／買斷 NT$100。
  不能把美元直接乘即時匯率當成上架價格，也不能再使用舊年方案或舊買斷價格。
- 訂閱的區域對應價格建立後，不會因匯率改變由 Apple 自動調整；一般買斷內購可選
  美國為基準，讓 Apple 定期更新其他自動管理地區的價格。跨區策略仍是建議。

來源：[Apple USD 價格表，第 1 頁](https://www.apple.com/newsroom/pdfs/App-Store-Pricing-Update.pdf#page=1)、
[自動續訂定價](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions)、
[一般內購定價](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/set-a-price-for-an-in-app-purchase/)。

### 使用者已確認的額度與到期規則 — 2026-09-16

- 每日額度依使用者所在地時區午夜更新，未用不累積。以伺服器時間及會員共用的 IANA
  時區計算，所有裝置共用同一視窗。時區變更不立即補額度；於既有視窗結束後生效，
  且至多每 24 小時生效一次，防止快速切換時區重複領取。這不代表能以 App Attest
  證明使用者的實際地理位置。
- 同時擁有買斷與訂閱，共用每日 1 次。依 9/21 最新權益，訂閱到期仍保留有效買斷的
  banner／日曆／每日 AI 權益。
- 成功生成並由伺服器可靠保存後才扣次；失敗退回同一筆每日／免費／廣告來源。
  重下載不扣次。重試結果保留 24 小時，過期不再提供；重新生成需明確確認新次數。
- 訂閱到期保留設定與既有排程。伺服器確認到期且沒有有效買斷等日曆權益後，
  下一次安全重排才改用基本規則；
  會員離線不視為確認到期，替換失敗不刪舊鬧鐘。若只選了日曆日期而未設每週重複日，
  保留既有排程，等待使用者選擇基本重複日。
- 免費方案初始 1 次加獎勵廣告。本機保留已使用計數，剩餘為 max(1 − 已用, 0)，
  已獲得的廣告額度不變；既存後端 ledger 不重置。不能直接信任舊手機申報為
  可花用的後端額度。遷移採先記錄待查核，尚未批准任何無證據補發或正式切換。

### 仍需開放前確認

- 台灣價格已於 9/21 指定；其餘商店價格、正式商品啟用及伺服器部署另行處理。
- 舊版本機免費／廣告次數沒有伺服器證明，轉入與舊匿名生成端點的切換方式待定。
  目前保留舊版流程，會員服務 URL 留空，沒有讓現有使用者餘額歸零。
- 會員刪除後防止重複領取所需的最少不可逆摘要，其正式保留期限與法規依據須審定。

### 買斷的持續服務成本

買斷包含持續提供每日 AI 生成，應以實際長期使用率評估；最新售價見 9/21 決策。以查核的 Gemini 2.5
Flash TTS 的音訊輸出費率（US$10／百萬 audio tokens、每秒 25 tokens），假設每次
上游實際生成 10 秒、全年每天使用 1 次，純音訊輸出為 US$0.9125／年；以預算假設
US$1 = NT$32 換算為 NT$29.20／年。這不是使用者平均成本或總成本，也不是成本上限，
未含文字輸入、語氣分析、伺服器、資料庫、失敗重試與其他支出。程式在收到音訊後才
裁切到 10 秒，上游實際生成更長仍可能增加費用。額外獎勵廣告收入不能當成每天內含
1 次一定會產生的收入。此成本檢核不自行改動使用者指定的價格或權益。

來源：[Google Cloud Text-to-Speech pricing](https://cloud.google.com/text-to-speech/pricing)，
2026-09-16 查核。

### English handoff

The latest decision (2026-09-21) offers only monthly subscription and non-consumable lifetime:
US$1/month and US$10 once in the US; NT$10/month and NT$100 once in Taiwan. Annual subscriptions
are no longer offered. This supersedes the September 16 three-plan pricing and September 17
provisional Taiwan annual/lifetime prices. Taiwan pricing is specified independently, not derived
from the US price. Other storefront prices remain undecided. StoreKit supplies displayed prices.
The subsequent September 21 entitlement decision gives both monthly and lifetime banner removal,
calendar and one shared daily ad-free AI generation. Lifetime is permanent access to these current
benefits and takes display priority when both are owned. Block redundant monthly purchases while
lifetime is active; keep the actual Apple subscription status and management entry without silently
cancelling it. Subscription expiry does not remove calendar while lifetime remains valid. Only a
verified loss of all calendar access triggers safe fallback planning. Additional generations still
require a rewarded ad; free remains one initial generation. Disaster closures stay deferred to
1.7.1, and their future lifetime eligibility is not decided by this change. Existing verified annual transactions must
still follow Apple's actual status; retiring a sale is not a refund or confirmed expiry.
The new US/Taiwan prices are saved and read back in ASC. Monthly/lifetime availability is US and
Taiwan only (2 territories), future-territory auto-expansion off. Annual is off sale (0 territories).
The lifetime US base-price change recalculated other Apple-managed territories; Taiwan was then
manually fixed at NT$100. Unavailable territories' generated prices are not approved prices. See
the staging record for evidence; no review submission, release or production membership activation occurred.
The user's latest September 21 confirmation and screenshot show Taiwan and US Sandbox testers
created (two visible rows). An inconsistent heading count does not override that evidence. Device
login, purchases and identity remain unverified; no credentials are recorded.
Approved quota rules remain local midnight without rollover, shared daily one for overlapping
purchases, durable-success debit with same-source refunds, and preserving settings/alarms until
safe replanning after confirmed expiry. Free users receive one initial generation plus rewards,
not a daily allowance. Legacy migration remains a launch gate. The cost example above remains a
historical audio-output-only scenario, not a current bill or profitability guarantee.

## iOS 1.7.0 integration decision — 2026-09-15

使用者已看過獨立預覽，現在授權將預覽功能與 UI/UX 邏輯合回原 `RainyClock-iOS/`
的 **1.7.0 (29)**，先在模擬器檢視。保留原 App 名稱、bundle ID、深色／藍色／圓角風格，
沒有另開發布版本、提交 App Store、部署後端或啟用收費。原獨立預覽及合入前備份仍保留。

- 狀態與設定分開。最左頁叫「鬧鐘」，顯示的資訊可前往對應設定；不將編輯控制全塞回狀態頁。
- 另一頁叫「設定」，分類為「時間／路線／日曆／其他」。「時間」取代設定分類原先的「鬧鐘」名稱。
- 編輯選項直接保存；不增加「套用變更」、設定完成訊息、「變更會自動更新」等多餘註解。
- 保留原路線編輯方式。國定假日、手動日期例外、天災設定與唯讀停班停課地圖歸「日曆」。
- 「其他」只保留支援與「通知與背景更新」相關內容；不增加「排程與資料」分類。
- 時間格式選項使用「12小時制／24小時制」名稱，不以「上午／下午」命名選項。
- 天災採「共用伺服器取得官方公告，手機更新本機排程」；每次颱風只更新資料，不需更新 App 版本。
- 日曆與天災預計為加值功能，但 **StoreKit 訂閱產品、價格上架及權益閘門尚未實作**。

The owner now authorizes integration of the reviewed previews into the original iOS 1.7.0 (29)
workspace for simulator review. The earlier separate-preview instruction was honored before this
authorization. The current navigation contract is Alarm / Settings, with Time / Route / Calendar /
Other categories; status links to settings and edits save directly. The disaster backend remains
undeployed/unconfigured, and APNs, physical-device scheduling and billing are not production-ready.
Prior preview test results are historical; the merged navigation and app require a fresh run.

This supersedes the September 10 deferral of temporary suspensions, the 366-day iOS 26 date window,
the map-only region selection restriction and older keyless/backendless day-off proposals below.
The current implementation uses a 27-day window and explicit, saved district selection; see
[DISASTER-PREVIEW.md](DISASTER-PREVIEW.md) for the complete current contract.

## Historical iOS 1.7.0 owner decisions — 2026-09-10

These supersede the earlier three-way work/school selector for iOS. Android is not changed.

- Work and school are independently enabled preferences; mixed-announcement semantics are
  deferred with temporary-suspension implementation.
- Manual date overrides have highest priority, including a forced ring on a holiday.
- 1.7.0 includes Settings, a monthly editor, Taiwan holidays and manual exceptions. Temporary
  suspensions remain a later version; the stored preferences do not yet silence alarms.
- Weekly selection is the baseline. The optional Taiwan office calendar removes official off
  days, including weekends. Users explicitly add make-up/shift days outside their weekly selection.
- Calendar master switch defaults off for new installs and 1.6.9 upgrades. Off hides its editor/source
  controls and uses only weekly rules, retaining manual dates for when the switch is re-enabled.
  Calendar overrides apply only to that exact year. Settings is the sole calendar entry point.
- Work/school regions come from the home/destination map points, with no manual district input.
  An unknown region stays pending; changing the route is how the user changes the region.
- Time format is a saved AM/PM or 24-hour preference (default AM/PM), shared by Alarm and evening
  previews, including their pickers and notification text. Chinese uses 上午/下午 only. A format
  change updates presentation, never the actual ring or notification firing time.
- Fixed-date coverage is explicit: 366 days on iOS 26+, 27 days on iOS 17–25, renewed when the app
  runs, with a seven-day expiry reminder. Later dates are saved rules, not yet armed alarms.

繁中：上班、上課是兩個獨立開關；手動響／不響優先於自動規則。1.7.0 完成國定假日與
月曆，臨時停班停課延後。預設沿用每週設定，選用台灣辦公日曆後排除政府休假日；額外
補班、輪班日可手動加回。每個例外僅適用該年該日，日曆會明示系統已排程的有效期限。
行事曆有獨立總開關，關閉就隱藏月曆等選項並保留原設定；入口只在設定頁。
上班／上課的地區從路線地圖帶入。時間可選 24 小時或上午／下午，套用鬧鐘和前晚通知。


## English

### Current Scope

Rainy Clock focuses on one commute profile: home to work. Users choose a commute mode, set a normal alarm time, select weekdays, set a rain lead time, and set a rain probability threshold. If weather around the next scheduled alarm check time meets the rain threshold, the app schedules an earlier local-notification alarm.

**The commute modes differ by platform, on purpose (2026-08-09).** iOS offers Car, Scooter, Walking and Transit; Android offers Car, Walking and Transit only. Google prices two-wheeler routing as an Enterprise-tier Routes API feature, outside the free Essentials allowance, while every other mode stays inside it. Scooters are the most common commute in this app's home market, so shipping the mode would have sent the majority of real traffic down the only billable path — on a free, ad-supported app currently earning US$0. Apple Maps has no two-wheeler mode and charges nothing, so iOS keeps the pill and quietly shows a driving estimate; there is no equivalent trick available on Android, where the honest choice is to not offer what we would be guessing at. Revisit if the app ever earns enough to absorb per-call routing costs.

### Weather Strategy

The app is structured around a `RouteWeatherService` protocol. The current release path uses `MapKitRouteWeatherService` with Apple Weather / WeatherKit.

The production implementation should:

1. Resolve home and work addresses.
2. Request a route for the selected commute mode.
3. Use the next selected weekday/time, minus the configured lead time, as the weather check time.
4. Query Apple Weather / WeatherKit for home-area and office-area weather around that check time.
5. Return whether either endpoint meets or exceeds the chosen rain probability threshold.

Open-Meteo is not part of the active release path.

**On-route sampling (queued for the next version, not in the shipped `1.6.5`):** the rain
check also covers interior points along the MapKit route — none under 4 km, the midpoint
from 4–20 km, quarter/mid/three-quarter points beyond — and *any* sampled point (home, en
route, office) over the threshold pulls the alarm earlier. Sampling is distance-based
because weather-model cells are a few km wide. Transit has no MKDirections geometry, and any
route failure silently degrades to the endpoint-only check: the alarm decision must never
depend on the routing infrastructure. The Android port ships the same rule
(`RouteSampler`), so both platforms decide identically.

### Address Strategy

Address entry should make resolution quality visible:

- If a user selects a dropdown suggestion, treat that result as confirmed.
- If the app resolves typed text without an explicit suggestion selection, show the actual address in use.
  Exception (1.7.1): when Apple matches the typed text *exactly* under the same name — differing only
  in case, width, diacritics, 臺/台, spaces or punctuation — and the text has no house number and no
  same-named place more than 2 km away, it is confirmed silently with its coordinate. "Taipei main
  station" → "Taipei Main Station" asked a question with nothing to decide; a chain name, a bare
  street number or any other name still asks.
- An unconfirmed or not-found address blocks scheduling, so the Home/Work row on the Route page must
  show it (yellow triangle / red mark), not only the address sheet.
- If an address cannot be resolved, mark only that address field as invalid.
- The “Use this location” action should replace the typed address with the resolved address.

Google Places fallback can be added later, but should only run when Apple address resolution fails and after a production API key is configured.

### Alarm Strategy

Scheduling is split by system version behind the `NotificationScheduling` protocol, with `SystemAlarmScheduler` picking the path:

- **iOS 26+ — AlarmKit (`AlarmKitScheduler`).** As of `1.6.3`, the alarm overrides silent mode and Focus, presents the system full-screen alert, and offers a native snooze through `Alarm.CountdownDuration.postAlert`. Snooze can be switched off, and its interval is user-selectable from 1–15 minutes. The sound picker also gains a "System Default Alarm" entry, which maps to `AlertConfiguration.AlertSound.default` — the only Apple tone reachable from a third-party app, since the Clock app's tone list lives in the private ToneLibrary with no public API. It is offered on iOS 26+ only; the notification path has no equivalent. Because the alarm can enter the countdown state, AlarmKit requires a widget extension — `RainyClockAlarmWidget` renders the snooze Live Activity, and without it the system may drop alarms entirely. Needs `NSAlarmKitUsageDescription` and a one-time user authorization; no special Apple entitlement.
- **iOS 17–25 — local notifications (`LocalNotificationScheduler`).** Still silenced by the ring/silent switch, which no `UNUserNotificationCenter` API can bypass. It has no snooze button, so the snooze setting drives the follow-up ring interval instead — the same "how long until it rings again" number, without the tap — and turning snooze off means the alarm rings exactly once. Critical Alerts would pierce silent mode here, but Apple grants that entitlement only to medical/safety apps.

**Deliberate behaviour change in `1.6.3` (iOS 26 only):** the pre-26 path fires follow-up notifications at the snooze interval, up to 10 times, whether or not the user reacts. AlarmKit instead alerts once and snoozes only when the user taps the button, matching Apple's Clock app. Layering backup notifications on top would restore the "keeps nagging" behaviour but re-introduce the two-mechanism bookkeeping AlarmKit exists to remove, so the system behaviour was accepted — a full-screen alert that pierces silent mode is far harder to sleep through than a banner.

**Scheduled-alarm sync contract (1.7.0 integration, 2026-09-15):** settings save directly and
parameter edits debounce into a schedule refresh. Foreground UI explicitly activates automatic
scheduling; the first alarm is armed only when both route addresses are confirmed and resolved
and the remaining alarm settings are valid. Draft address typing cannot arm an alarm. Editing
an existing address removes the old route's schedule; a newly confirmed, resolved route can be
automatically scheduled without an Apply button. The Alarm tab reports actual schedule state and
links to the relevant editor; errors or pending changes must not appear as confirmed success.

The intended product behavior is to refresh weather at the configured lead-time point. For example, if the normal alarm is 7:30 and the rain lead time is 30 minutes, the app checks the selected route/weather at 7:00. If the threshold is exceeded, the early alarm fires; otherwise, the normal alarm remains.

### Day-off Suppression

Current iOS implementation is integrated locally into 1.7.0 (29), following the owner's
September 15 approval. The earlier backendless/keyless proposal in `DAYOFF-SPEC.md` is
historical where it conflicts with [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md).

- A shared server reads the official NCDR member Atom/CAP API, validates/caches announcements,
  and optionally sends APNs background hints. Each event changes data, not the App Store binary.
- iOS uses the original alarm date and explicitly saved home/destination districts; either
  selected location may qualify. Route interior points do not qualify. Work/school switches
  remain independent; both enabled currently requires both suspended (AND).
- Unknown, stale, conflicting or mismatched announcements do not create new skipped alarms.
  Confirmed applicable announcements may skip that date only. Manual ring overrides in an enabled
  calendar take precedence. Scheduling success is recorded separately from receiving an announcement.
- Authenticated receipts report completed local processing only. They contain no location, alarm
  time or skipped date, and cannot promise future delivery or alarm behavior.
- Holidays use the official offline office-calendar CSV, not EventKit. The read-only map lives
  under Calendar and is separate from both alarm scheduling and the date editor.
- The feature defaults off. Deployment, NCDR/APNs credentials, physical-device behavior, the
  27-day date-window limitation and StoreKit billing remain release work. No production service
  or subscription was activated by this local integration.

### Localization Strategy

All user-facing UI text should be backed by localized string resources. Documentation should include both English and Traditional Chinese so product and technical decisions stay aligned across languages.

---

## 繁體中文

### 目前範圍

Rainy Clock 聚焦在單一通勤設定：住家到公司。使用者可以選擇通勤方式、設定平常鬧鐘時間、選擇星期、設定雨天提前時間與降雨機率門檻。若下一次鬧鐘判斷時間附近的天氣達到降雨門檻，App 就會提前安排本機通知鬧鐘。

**兩個平台的通勤方式刻意不同（2026-08-09 決定）。** iOS 提供開車、騎車、步行、大眾交通；Android 只提供開車、步行、大眾交通。Google 把兩輪路線（`TWO_WHEELER`）歸類為 Routes API 的 Enterprise 等級功能，不在 Essentials 的免費額度內，而其他三種模式都在額度內。機車是本產品主力市場最常見的通勤方式，保留這個選項等於讓**多數**真實流量走上唯一要付費的路徑——而這是一款目前收入為 US$0 的免費含廣告 App。Apple Maps 沒有兩輪模式且不收費，所以 iOS 保留這個選項、實際顯示的是開車的時間估計；Android 沒有這種取巧空間，誠實的做法就是不提供我們只能用猜的功能。若日後廣告收入足以吸收每次呼叫的路線費用，可以重新評估。

### 天氣策略

App 以 `RouteWeatherService` protocol 作為路線天氣抽象層。目前上架版本流程使用 `MapKitRouteWeatherService` 與 Apple Weather / WeatherKit。

正式版實作應該：

1. 解析住家與公司地址。
2. 依照使用者選擇的通勤方式查詢路線。
3. 使用下一個符合星期與時間設定的鬧鐘時間，扣掉雨天提前時間，作為天氣判斷時間。
4. 透過 Apple Weather / WeatherKit 查詢該時間附近的住家與公司附近天氣。
5. 回傳任一端點是否達到或超過使用者設定的降雨門檻。

Open-Meteo 已不在目前上架版本的主要流程中。

**路線途中取樣（排入下一版，未包含在已送審的 `1.6.5`）：** 降雨判斷同時涵蓋 MapKit 路線
上的內部取樣點——4 公里以下不取、4–20 公里取中點、更長取 1/4、1/2、3/4 三點——住家、
途中任一點、公司**任一處**超過門檻就提前響鈴。以距離為基準是因為天氣模型的網格本來就有
數公里寬。大眾運輸拿不到 MKDirections 路線幾何；任何路線查詢失敗都靜默退回只查兩端點，
鬧鐘判斷絕不依賴路線基礎設施。Android 版用同一套規則（`RouteSampler`），兩平台判斷一致。

### 地址策略

地址輸入應清楚顯示解析品質：

- 如果使用者從下拉式建議選單選取，視為已確認地址。
- 如果 App 直接用輸入文字解析出地址，但使用者沒有明確選取建議，顯示實際使用地址。
- 如果某個地址無法解析，只將該地址欄位標示為無效。
- 「使用此位置」按鈕應將輸入文字替換為實際解析出的地址。

Google Places fallback 可在未來加入，但只應在 Apple 地址解析失敗時啟用，且必須先設定正式 API key。

### 鬧鐘策略

排程依系統版本分成兩條路徑，都藏在 `NotificationScheduling` protocol 後面，由 `SystemAlarmScheduler` 選擇：

- **iOS 26 以上 — AlarmKit（`AlarmKitScheduler`）。** 自 `1.6.3` 起，鬧鐘會穿透靜音與專注模式，顯示系統全螢幕警示，並透過 `Alarm.CountdownDuration.postAlert` 提供原生賴床；賴床可關閉，間隔可在 1–15 分鐘之間選擇。鬧鈴清單也多了「系統預設鬧鈴」，對應 `AlertConfiguration.AlertSound.default` —— 這是第三方 App 唯一拿得到的 Apple 音色，時鐘 App 那整份鈴聲清單住在私有的 ToneLibrary，沒有公開 API。此選項僅在 iOS 26 以上出現，通知路徑沒有對等物。因為鬧鐘會進入 countdown 狀態，AlarmKit 要求必須有 widget extension —— `RainyClockAlarmWidget` 負責畫賴床 Live Activity，沒有它系統可能直接放棄鬧鐘。需要 `NSAlarmKitUsageDescription` 與一次性使用者授權，不需要向 Apple 申請特殊 entitlement。
- **iOS 17–25 — 本機通知（`LocalNotificationScheduler`）。** 靜音下仍然不會有聲音；`UNUserNotificationCenter` 沒有任何 API 能繞過靜音開關。這條路徑沒有賴床按鈕，所以賴床設定改為控制補發響鈴的間隔 —— 同樣是「隔多久再響一次」，只是不需要使用者按；關閉賴床就代表鬧鐘只響一次。Critical Alerts 能穿透靜音，但 Apple 只發給醫療／安全類 App。

**`1.6.3` 刻意的行為改變（僅 iOS 26）：** 舊路徑不管使用者有沒有反應，都會依賴床間隔補發、最多 10 次。AlarmKit 改成響一次，只有使用者按賴床才會再響，與 Apple 時鐘 App 一致。若在上面再疊備援通知，可以保留「不理也會再吵」的行為，但會把 AlarmKit 本來就要消除的雙機制同步複雜度搬回來，所以選擇接受系統行為 —— 穿透靜音的全螢幕警示本來就比橫幅通知難忽略得多。

**排程鬧鐘同步約定（1.7.0 整合，2026-09-15）：** 設定直接保存，參數變更經短暫 debounce
自動更新排程。前景 UI 明確啟用自動排程後，只有住家、目的地**兩個地址都已確認且解析完成**、
其餘鬧鐘條件也有效，才建立第一個鬧鐘；正在輸入的地址草稿不會觸發。修改既有地址先移除舊
路線鬧鐘，新路線確認完成後可自動建立，不需要「套用」按鈕。鬧鐘頁呈現實際排程狀態並連往
對應設定；錯誤或待套用狀態不能顯示為確定成功。

預期產品行為是在使用者設定的提前時間點刷新天氣。例如平常鬧鐘是 7:30、雨天提前時間是 30 分鐘，App 應在 7:00 檢查路線與天氣。如果超過門檻，提早鬧鐘響起；否則保留正常鬧鐘。

### 停班停課與假日靜音

2026-09-15 已依使用者授權整合至本機 1.7.0 (29)。早期 `DAYOFF-SPEC.md` 的免金鑰、
無後端與只在響鈴時說明的提案，與目前實作衝突時以 [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md) 為準。

- 共用伺服器取得 NCDR 正式會員 Atom/CAP，驗證及快取公告，再以選用 APNs 提醒手機同步；
  每次颱風更新資料，不需要使用者下載新版 App。
- 手機比對原鬧鐘日期及使用者確認的住家／目的地鄉鎮市區，任一已選地點可符合；不檢查途經地區。
  上班、上課分別勾選，兩者皆選時任一停止即略過（2026-09-22 決定，取代原先暫採的 AND）。
- 未知、過期、矛盾或日期不符的公告不新增略過；明確符合時只略過該日期。已啟用日曆中的
  手動「照響」優先。公告已取得與系統排程已成功是不同狀態。
- 手機成功處理後才上傳認證回報，不含位置、鬧鐘時間或略過日期；回報不是持續在線、
  推播一定送達或未來鬧鐘狀態的保證。
- 國定假日使用官方離線辦公日曆 CSV，不用 EventKit。唯讀行政區地圖放在「日曆」，
  與日期編輯及鬧鐘是否成功略過分開。
- 功能預設關閉；伺服器部署、NCDR／APNs 金鑰、真機背景行為、27 天日期視窗的產品限制
  及 StoreKit 收費仍待完成。這次本機整合沒有啟用正式服務或訂閱。

### 本地化策略

所有使用者可見的 UI 文字都應由本地化字串資源提供。文件應同時提供英文與繁體中文，確保產品與技術決策在兩種語言中保持一致。

## 2026-09-23 — 颱風推播：廣播給所有裝置，手機自己判斷（作法 B）

使用者最擔心的是「整晚沒點開 App 就錯過公告」。iOS 的靜默推播與背景更新都不保證執行，所以改為：伺服器對所有登記裝置送**同一則可見推播**，不含任何位置資料；手機的 Notification Service Extension 在 App 未執行時被系統喚醒，比對 App Group 裡使用者確認過的住家／目的地行政區，把通知改寫成「符合／相關／無關（靜音）」。伺服器不保存縣市或行政區，隱私政策只需說明推播 token 與匿名註冊。被拒絕的替代方案：伺服器保存裝置縣市再分區推送（多一筆位置資料）；每兩小時定時拉取（iOS 不提供這種排程）。鬧鐘的略過仍只由 App 自己決定，推播只是通知。詳見 [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md)「推播與整晚沒碰手機的使用者」。

同日另決定：停班、停課兩者都勾時是 OR，任一公告符合即略過（spec v3）。使用者看過模擬器推播截圖後確認作法 B 的結果，正式納入 1.7.1 範圍。

## 2026-09-15 — 天災停班停課實作與後續整合

本次採用共用伺服器輪詢官方 NCDR Atom/CAP，手機保留地區及判斷邏輯；停班資訊可隨時更新，每日一次不足。只在成功調整指定日期鬧鐘後宣稱已略過，疑慮與失敗不新增略過。功能明確預設關閉，兩勾選暫採 AND；付費權益尚未接入。本版採 27 天固定日期視窗並顯示期限，對應限制與部署需求見 [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md)。最初於獨立預覽實作，現在經使用者授權整合回原 1.7.0 開發目錄；仍未發布。

使用者已確認採用「共用伺服器查公告，手機同步後調整鬧鐘」。事件變更不需要更新 App 版本。新增手機成功處理回報：APNs 送出、手機下載成功與本機排程成功是不同狀態；伺服器只保存最新公告版本及處理結果／時間，不收集位置或鬧鐘日期。Receipt is a historical acknowledgement, not a delivery or future alarm guarantee. 部署與真機驗證仍未完成。

使用者要求加入台灣行政區顏色地圖。原生畫面依今天／明天公告呈現鄉鎮市區，不把無公告當成正常。地圖與鬧鐘設定分開；住家與目的地卡片只定位，經過地區不列入判斷。公告原文保留，部分時段／地區另色，不擴張成全天整區停班。圖資離線隨 App 保存，示範資料明確標示且不修改真實鬧鐘。Native map implementation and display-only boundaries are documented in [DISASTER-MAP-PREVIEW.md](DISASTER-MAP-PREVIEW.md).
