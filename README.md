# PhotoSync

把 iPhone 相簿單向同步到 NAS（SMB 共享）的個人用 iOS App。照片和影片會依你設定的檔名與資料夾範本存到 NAS，不會從 NAS 往回抓。

## 功能

- 用 SMB（含 SMB3 加密）連到 NAS，遠端根目錄用資料夾瀏覽器選。
- 首頁是相簿瀏覽器：縮圖外框顏色表示同步狀態（藍框＝尚未同步，灰框＝已同步）。
- 檔名和子目錄都能用範本，例如拍攝日期、原檔名、相簿名稱；日期用「拍攝當下的當地時間」。
- 可選 HEIC 轉 JPEG、影片轉 H.264、Live Photo、寫入拍攝時間到遠端檔案。
- 同名檔自動加 `_1`、`_2` 後綴，也可選擇跳過或覆蓋；上傳先寫 `.part`，完成才改成正式檔名，中斷的半截檔不會被當成成品。
- 相簿可個別隱藏並停止同步。
- 同步紀錄頁，保留最近 30 天。
- 密碼存在 Keychain。

## 需求

- iOS 18.0 以上
- 建置需要 Xcode 與 Swift 6 工具鏈（macOS 15 以上）

## 安裝

### 從 Xcode 執行

打開 `PhotoSync.xcodeproj`，選 `PhotoSync` scheme 後執行。需要簽署，沒簽署的建置沒有 Keychain entitlement，密碼會存不進去。

### 產生 IPA

```bash
scripts/build-ipa.sh    # 輸出 build/ipa/PhotoSync.ipa
```

這會產生**未簽署**的 Release、arm64 IPA（bundle id `com.konnokai.PhotoSync`），再交給 Sideloadly、AltStore 之類的工具簽署安裝。簽署工具要提供 Keychain entitlement，否則設定頁密碼欄下會出現 `-34018` 的紅字。

## 使用

1. 到設定頁填 NAS 主機、共享名稱、帳號和密碼，選遠端根目錄。
2. 設定檔名與子目錄範本（預設保留原檔名）。
3. 回首頁，點右上角紅色按鈕開始同步，再點一次停止。
4. 進度顯示在底部列；失敗項目維持藍框，下一輪會重試。

## 專案結構

| 目標 | 內容 |
| --- | --- |
| `SyncCore` | 範本引擎、衝突解析、同步引擎、log。只依賴 Foundation，靠 `SMBClient`／`PhotoSource` 兩個協定隔離外部 |
| `SMBAdapter` | 用 [AMSMB2](https://github.com/amosavian/AMSMB2) 實作 `SMBClient` |
| `PhotoSource` | 用 PhotoKit／ImageIO／AVFoundation 實作 `PhotoSource` |
| `App/` | SwiftUI 殼：設定、進度、log、Keychain、背景任務 |

## 開發

```bash
swift test                                   # 單元測試（macOS）
swift test --filter SyncEngineTests          # 只跑一個測試類別
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

對真實 SMB 伺服器的整合測試，沒設環境變數會自動跳過：

```bash
PPS_SMB_HOST=127.0.0.1 PPS_SMB_PORT=1445 PPS_SMB_SHARE=photos \
PPS_SMB_USER=<帳號> PPS_SMB_PASS=<密碼> swift test --filter SMBIntegrationTests
```

SMB3 加密、背景任務、iCloud 原檔要實機驗證；單元測試用假的 `SMBClient` 驗證邏輯。

## 文件

- [docs/implementation-notes.md](docs/implementation-notes.md)：和計畫書不同的取捨、同步判斷規則、首頁行為、本機 Samba 測試伺服器設定。
- [docs/personal-sync-tool-plan.md](docs/personal-sync-tool-plan.md)：原始需求。
- [docs/photosync-home-display-analysis.md](docs/photosync-home-display-analysis.md)：首頁顯示規格。
