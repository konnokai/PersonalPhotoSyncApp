# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

PhotoSync：自用的 iOS App，單向把相簿同步到 NAS 的 SMB 共享。文件與註解用繁體中文。`docs/implementation-notes.md` 記了大量實作取捨（衝突解析、指紋、時區、Keychain 等），改行為前先讀它；需求原文在 `docs/personal-sync-tool-plan.md`，首頁規格在 `docs/photosync-home-display-analysis.md`。

## Lessons

- 從 NAS 檔案時間推論使用者的日期界線時，遇到空窗期要先問使用者那段時間有沒有用別的裝置，再改建議。
- 使用者要求「上傳某種檔案」時，先確認同步是不是已經原檔上傳這種格式，再決定要不要加轉檔或新選項。

## 指令

```bash
swift test                                   # 全部單元測試（macOS，SyncCore / PhotoSource / SMBAdapter）
swift test --filter SyncEngineTests          # 單一測試類別
swift test --filter SyncEngineTests/testXxx  # 單一測試
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
scripts/build-ipa.sh                         # 未簽署 IPA → build/ipa/PhotoSync.ipa
```

- iOS 建置不要加 `CODE_SIGNING_ALLOWED=NO`：沒簽署就沒有 Keychain entitlement，密碼存不進去（`-34018`）。`build-ipa.sh` 是例外，因為簽署交給後續工具。
- 沒有 lint 設定。
- `SMBIntegrationTests` 要設 `PPS_SMB_HOST/PORT/SHARE/USER/PASS` 才會跑，否則自動 skip。本機 Samba 的設定眉角見 `docs/implementation-notes.md`「本機 SMB 測試伺服器」。
- App 本體（`App/`）沒有單元測試，只能靠模擬器驗證；SMB3 加密、背景任務、捷徑自動化、iCloud 原檔要實機。

## 架構

SwiftPM 套件（`Package.swift`）加一個手寫的 Xcode 專案（`PhotoSync.xcodeproj`，只含 `App/`，把套件當本機依賴）。新增 `App/` 檔案要同步改 `project.pbxproj`。

```
App (SwiftUI) ─┬─> SyncCore        純邏輯，只依賴 Foundation
               ├─> SMBAdapter  ──> SyncCore, AMSMB2
               └─> PhotoSource ──> SyncCore, PhotoKit/ImageIO/AVFoundation
```

- **SyncCore** 靠兩個協定（`Protocols.swift`）隔離外部世界：`SMBClient`（遠端檔案操作）與 `PhotoSource`（列舉資產、匯出檔案）。`SyncEngine` 只認這兩個協定，所以測試用 `Tests/SyncCoreTests/Fakes.swift` 的假實作就能涵蓋引擎邏輯。新功能優先放 SyncCore 並用假物件測，不要把邏輯塞進 adapter 或 View。
- **SyncEngine** 流程：列舉資產 → 用 `NameTemplate` 算遠端路徑 → 沿 `name`、`name_1`… 解析衝突（判斷同名檔是否「這個項目自己的」的規則在 `docs/implementation-notes.md`）→ 匯出到暫存檔 → 傳成 `.part` → 搬成正式檔名 → 寫時間戳。連線中斷或連續失敗會停整輪。
- **SMBAdapter**（`AMSMBClient`）把 AMSMB2 包成 `SMBClient`；libsmb2 失敗時錯誤碼不精確，連線失敗後會自己探測原因。取消時一律丟 `CancellationError`。
- **PhotoSource**（`PhotoKitSource`）實作 `PhotoSource`；`CaptureOffset` 從 EXIF／QuickTime 讀拍攝當下的 UTC 偏移。
- **App**：`AppModel` 持有狀態並驅動引擎，`Views.swift` 是全部畫面，`Keychain.swift` 存密碼，`SyncIntents.swift` 是捷徑（App Intent）的「同步相簿」動作，直接呼叫 `AppModel.shared.sync()`。持久化檔案都在 `Documents/`：`synced-ids.json`（已同步集合＋指紋）、`capture-offsets.json`、`sync-log.jsonl`。

### 改動時要注意的連動

- 「已同步」集合綁一個指紋（主機、共享、根目錄、檔名／子目錄範本、轉檔選項、備用時區等）。新增會影響遠端路徑或內容的設定，要判斷是否加進指紋，並同步 `docs/implementation-notes.md` 的指紋清單。
- `SyncConfig` 欄位變動要同時看 `AppModel`、`Views.swift` 的設定頁與測試。
- 子目錄預設清單在 `SubdirectoryPreset`；設定頁範例路徑是用 `NameTemplate.render` 算的，不是寫死字串。
- 全部 target 用 Swift 5 語言模式（`.swiftLanguageMode(.v5)`），套件工具版本是 6.0；最低 iOS 18 / macOS 15。
- `.bak-*`、`build/`、`.build/` 已被 gitignore。
