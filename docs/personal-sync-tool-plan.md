# 自用相簿同步工具 計畫書

版本：草案 v0.2（2026-10-13）
範圍：僅規劃，不含實作。

## 1. 目標

一支自用、單向的同步工具：把 iPhone 系統相簿裡的照片與影片同步到家用 NAS 的 SMB 共享資料夾。核心需求只有三件事：

1. 正確地從 PhotoKit 取出原始（或指定格式）的檔案資料。
2. 以穩定的方式透過 SMB2/3 上傳，中途斷線不留半成品。
3. 增量同步：第二次以後只傳新增／有變更的項目。

不做的：反向下載、多雲端服務、帳號體系、SMB1 支援、上架需求（如 App Store 審查相關的功能）。

## 2. 技術選型

| 用途 | 選擇 | 理由 |
| --- | --- | --- |
| SMB2/3 客戶端 | AMSMB2（Swift Package，內含 libsmb2） | 成熟、純 Swift 介面（`uploadItemFrom:`、`writeStream:toPath:chunkSize:`），協定不用自己碰 |
| 照片讀取 | `PHAssetResource` + `PHAssetResourceManager writeDataForAssetResource:toFile:options:` | 可拿到最上游的原始檔（含 RAW／Live Photo 配對 mov），`networkAccessAllowed=true` 時可從 iCloud 取回未下載的原圖 |
| 影片讀取 | 預設直傳原始 resource；轉碼才用 `AVAssetExportSession` | 重編碼既慢又損品質，只在目標裝置需要時開 |
| 暫存 | `NSTemporaryDirectory()` 下以 UUID 命名，上傳完即刪 | 大檔不塞在記憶體，也不污染 Documents |
| 設定／密碼 | 設定存 `UserDefaults`，NAS 密碼存 iOS Keychain | 一樣的通行做法，密碼不落明文 |

## 3. 管線設計（三階段）

```
PhotoKit 選材 → 暫存產檔 → SMB 分塊上傳 → 改正式名 → 寫時間戳
```

### 3.1 Phase 1 — 選材

- 來源：`PHPhotoLibrary` + `PHFetchOptions`，依使用者選的相簿集合（全部相簿或指定相簿）列舉 `PHAsset`。
- 增量策略：以「遠端清單 diff」為準——每次同步前用 AMSMB2 `contentsOfDirectoryAtPath:` 列出遠端既有檔（檔名、size、mtime），本地檔案算出目標檔名後不在遠端清單即上傳。
  - 好處：不需要維護本機同步資料庫，重裝 App 也不會整批重傳。
  - 保底：NAS 上同名但 size 不同 → 走衝突規則（3.4）。

### 3.2 Phase 2 — 產檔

- 照片：`+[PHAssetResource assetResourcesForAsset:]` 先找最上游 resource，寫入暫存檔。
- HEIC：預設原檔保留；提供「轉 JPEG」開關（Phase 2 才做，`CGImageSource`/`CGImageDestination`）。
- 影片：預設直傳；「轉 H.264」開關放 Phase 2（preset `AVAssetExportPresetHighestQuality` 起步）。
- Live Photo／Burst 進階處理：Phase 3 選配。
- 檔名：範本引擎只支援一組基本變數與固定模式（見 3.4 之前，拆在 3.3）。

### 3.3 檔名與子目錄範本

預設提供兩層選擇：

- 固定模式（內建，不佳選項的兜底）：
  - 模式 0：保留原檔名。
  - 模式 1：`YYYY-MM-DD_HH-MM-SS.<副檔名>`（拍攝時間前綴）。
  - 模式 2：`YYYY-MM-DD_HH-MM-SS_<原檔名>.<副檔名>`。
- 變數範本（簡版）：支援下列 token，時間用拍攝日期：
  - `%YR`、`%yR`、`%mR`、`%dR`、`%HR`、`%MR`、`%SR`（年、月、日、時、分、秒）。
  - `%OP` 原檔名（不含副檔名）、`%ID` UUID、`%AP` 相簿名（照片所在的使用者相簿，多個相簿取名稱排序最前者；不在任何相簿則為「最近項目」）、`%DP` 設備名、`%EP` 副檔名。
  - 序號 `%IP`（必要時自動補在連序檔名之後）。
- 子目錄：設定頁提供預設範本可直接選（無、相簿名稱、裝置名稱／相簿名稱、裝置名稱、副檔名、年、年/月、年/年-月、年-月-日、年/月/日、裝置/年-月），也可選「自訂」手寫範本。預設只收目前 token 能穩定表達的項目；傳檔日期不收（同一張照片每天會換資料夾），檔案類型沒有對應 token，也不收。
- 遠端根目錄：設定頁用資料夾瀏覽器選（連上 NAS 後逐層點進去，選擇目前這層）。路徑相對於共享根目錄、不帶開頭斜線。不提供新增資料夾，同步時引擎會自動建立不存在的目錄。
- 附加規則：副檔名可設定統一大／小寫；檔名內不合法字元一律替換為 `_`；子目錄範本與檔名範本同一套變數（如 `YYYY/YYYY-MM/`）；不做函式階（substr／pad…）。

### 3.4 上傳與衝突語意

- `createDirectory` 逐層建目標子目錄。
- 原子寫：上傳到 `.<final>.part` 暫存名，成功後 `moveItem` 改正式名；斷線只留孤兒暫存檔，不留半成品。
- 同名同 size：跳過（重跑情境）。
- 同名不同 size：檔名尾巴加 `_1`、`_2` …。
- 上傳成功後依設定把 creation/mtime 寫成拍攝時間（AMSMB2/libfsmb2 的 set time API），讓 NAS 端 mtime 可作為備援排序依據。
- 中途失敗：清掉 `.part`；同一輪內重試（次數可設定，預設 2）後跳過並記 log。

### 3.5 並發與生命周期

- 單一串列佇列（1 併發）起步，避免對 NAS 過度並行；上限保留為常數可調。
- 前景手動觸發為主；背景自動同步放 Phase 2，用 `BGProcessingTaskRequest` + network 束縛條件。
- 每次同步一則 log（時間、檔名、結果、錯誤、耗時、bytes），寫到 `Documents/`。

## 4. 設定清單（合計 ≤ 10 項）

host/port、share、帳號、密碼（Keychain）、遠端根目錄、來源相簿（單選或全部）、檔名範本、副檔名大小寫、衝突策略、每檔重試次數。

## 5. 里程碑

| 里程碑 | 內容 | 驗收 |
| --- | --- | --- |
| M1 後端管線 | AMSMB2 連線、列目錄、上傳測試檔、原子改名、時間戳 | `test1.jpg` 在 NAS；拔網路重試後無半成品 |
| M2 基本同步 | PhotoKit 選材 + 暫存產檔 + 批次上傳；檔名模式 0/1/2 | 兩輪同步：第一輪全量，第二輪 0 變動（遠端 diff 生效） |
| M3 使用介面 | 設定頁、進度頁、log 頁；手動「開始同步」 | 新裝置第一次同步可自動接續（因為走遠端 diff） |
| M4 精進 | HEIC→JPEG、影片轉碼、Live Photo、背景 BGProcessingTask | 依開關逐一驗收 |

## 6. 風險與待驗證事項

1. SMB3 加密：AMSMB2/libsmb2 預設是否啟用加密需在 M1 對自家 NAS 實測確認。
2. iCloud 未下載的原片：`networkAccessAllowed=true` 可取回，但背景模式會受系統限制；M2 實測後把 iCloud-only 照片列為「需前景」或跳過。
3. 大檔暫存：4K 影片落在暫存盤佔空間；「上傳完即刪」已緩解，加個暫存上限提示即可。
4. 增量語意：遠端 diff 對「只改過照片 metadata（不變 size）」的項目會視為已同步，屬刻意取捨，列入說明。
