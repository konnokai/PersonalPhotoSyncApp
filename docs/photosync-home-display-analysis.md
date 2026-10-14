# PhotoSync 首頁圖片顯示與同步狀態顯示 — 顯示機制規格

版本：v1.1（2026-10-13）
範圍：行為規格整理，不含實作。
前一份計畫書：`personal-sync-tool-plan.md`（已在其他分支執行，本份為獨立新文件）。

參照對象：PhotoSync for iOS 4.9.7（`com.touchbyte.PhotoSync`，MinimumOSVersion 12.0）。本文件描述它的實際顯示行為，作為自用同步工具 UI 的實作參照；數值（顏色、尺寸、狀態值、持久化欄位）均已核對過原始程式行為。

## 1. 結論摘要

首頁就是「系統相簿瀏覽器」：`AlbumContentsViewControllerPhotoKit` 用 UICollectionView 把 `PHFetchResult`（PhotoKit）以縮圖格狀展示。每張縮圖的「已同步／尚未同步」不是用文字或角標圖示，而是**縮圖外框顏色**：

| 狀態（mediaObjectState） | 意義 | 視覺 |
| --- | --- | --- |
| 2 | new＝尚未同步、未選取 | 藍色框（flat light 主題 `#21A7FB`、flat dark `#52BBFD`） |
| 4 | new＋已選取 | 藍色框＋黑色 20% 覆蓋層＋右下角選取勾勾圖示（`flat_thumbselected`） |
| 1 | synced＝已同步、未選取 | 灰色框（flat light `#DDDEDB` 2pt、flat dark 40% 灰 1pt），無覆蓋層 |
| 3 | synced＋已選取 | 灰色框＋黑色 20% 覆蓋層＋右下角選取勾勾 |
| 5 | 無效（asset 為 nil 時的回傳值） | 當作 synced 樣式（type 8），不影響實際畫面 |

「已選取」（要傳送的項目）＝狀態 3、4；「尚未同步」＝狀態 2、4（`DataProvider` 的 predicate 直接驗證了這組語意，見 §5）。

## 2. 首頁的組成

1. 啟動：`-[PhotoSyncAppDelegate initAdaptiveLayoutAnimated:]` 依主題載入 `MainAdaptive` / `MainAdaptive_light` / `MainAdaptive_automatic` storyboard（`UIStoryboard storyboardWithName:bundle:` → `instantiateInitialViewController`），設為 window root。storyboard 編譯產物 `MainAdaptive.storyboardc/` 內含 `AlbumController.nib`（相簿清單）與 `AlbumContentsController.nib`（照片網格）。
2. `AlbumViewControllerBase`（相簿清單）的 delegate 指向 `albumContentsViewController`；iPhone 尺寸類別 collapse 後，使用者看到的主要畫面就是照片網格。
3. `-[AlbumContentsViewControllerBase viewDidLoad]`：設定 `selectedSyncMode=5`、`fileCellType`（讀設定 `libraryDisplayMode`）、`quickLookMode`、註冊通知、`collectionViewSetup`。
4. `-[AlbumContentsViewControllerBase collectionViewSetup]`：dataSource/delegate 設 self、背景色 `TBThemeManager colorWithType:0`、iOS10 之後關閉 prefetching、直向 flow layout（header 高 58，moment 分組用）、加單擊 `handleSingleTap:` 與雙擊手勢、加 pull-to-refresh。
5. 資料來源：`-[AlbumContentsViewControllerPhotoKit viewDidLoad]` 向 `PHPhotoLibrary` `registerChangeObserver:`，fetch result 由 `TBPhotoLibraryHelper`（moments／相簿／智慧相簿分組）提供。

## 3. 儲存格結構（程式碼建立，非 nib）

`-[PHCollectionViewBaseCell initWithFrame:]` 純程式碼組出子視圖：

| 子視圖 | 用途 | 外觀 |
| --- | --- | --- |
| `_imageView` | 縮圖主體 | clipsToBounds、layer 一律先套 `TBThemeManager customizeLayer:type:8` |
| `_specialIconBanner`（疊在 imageView 內） | 影片／連拍／RAW 標示條 | 底部全寬 18pt 條，背景黑 alpha 0.5 |
| `_specialIconView` | 條內圖示 | `video_symbol`（imageNamed）、`slomo_symbol`／`timelapse_symbol`／`burst_symbol`／`raw`／`rawjpg`（主題 `imageWithType:36~39` 等，見 `+[PHCollectionViewBaseCell initialize]`） |
| `_coverView`（疊在 imageView 內） | 選取覆蓋層 | 黑 alpha 0.2，`hidden` 依狀態控制 |
| `_selectionIconView`（疊在 coverView 內） | 選取勾勾 | 圖示＝主題 `imageWithType:36`＝`flat_thumbselected`，置於右下角（`layoutSubviews`：x＝寬−icon 寬−2、y＝高−icon 高−2） |
| `_favoriteLabel` | 好收藏記號 | 右上角 16×16，屬性文字「♥」白字灰描邊，顯示條件＝asset 有收藏且設定 `showFavoriteSymbol` |

實際使用的 cell 類別：`fileCellType==1`（列表+資訊模式）用 `PHDetailCollectionViewCell`（60pt 縮圖＋`textLabel1/2/3` 顯示檔名、大小−日期、像素尺寸或片長；檔名取不到時顯示雲朵字元 U+2601），否則用 `PHSymbolCollectionViewCell`（純縮圖）。cell 由 `dequeueReusableCellWithReuseIdentifier:` 取得，identifier 直接是類別名字串。

## 4. 縮圖的產生流程（首頁照片）

`-[AlbumContentsViewControllerPhotoKit collectionView:cellForItemAtIndexPath:]`：

1. 依 `reverseSort` 與 moment 分組從 `PHFetchResult` 取 `PHAsset`；`cell.uuid = asset.localIdentifier`、`cell.asset = asset`（此處觸發 `updateStateDisplay` 畫出狀態框）、`cell.collection = groupObject.collection`、`cell.thumbDisplayMode`。
2. 列表模式額外組 `MediaObject`＋`RepresentationObject` 取檔名／大小，填三個 label。
3. 建立 `PHThumbnailDownloaderOperation`：
   - `initWithAsset:size:imageManager:completionBlock:`，size＝`imageManagerRequestSize`＝格點尺寸 × 螢幕 scale（列表模式固定 60×60）。
   - `start`：`PHImageRequestOptions` 設 `networkAccessAllowed=YES`（可從 iCloud 取回縮圖）、`deliveryMode=1`（high quality format），然後在 main queue 對 `PHCachingImageManager`（無則 `PHImageManager defaultManager`）呼叫 `requestImageForAsset:targetSize:contentMode:options:resultHandler:`。
   - result handler 把圖存進 `downloadedImage`、叫 `thumbnailDownloaderCompletionBlock`、`setState:2`（完成）。
4. cellForItem 的 completion block：**先比對 `cell.tag`**（cellForItem 進場時 tag+1，防止重用 cell 收到舊圖），相符才 `setThumbnailImage:` → `imageView.image` ＋ `updateThumbnailAspect`（依圖片長寬調整）。
5. operation 加入 `DataProvider.thumbQueue`；每個 asset 的進行中 request 記錄在 `_networkRequests[localIdentifier]`，離畫面時可取消。

遠端／雲端媒體用的 `ThumbnailRenderer`／`PHThumbnailRendererOperation`（`renderLayerOfSize:suppliedImage:completionBlock:`）是同一套狀態規則的 layer 版：state 2/4 → layer 套 type 10（藍框）；state 3/4 → 加一層黑色（alpha 0.2）的覆蓋 CALayer（insertSublayer atIndex 2，opacity 依是否選取設 1.0／0.0）；其餘 type 8。也就是說同一組視覺規則在 cell（UIImageView）與渲染出的 CALayer 兩處各實作一次。

## 5. 同步狀態的資料模型

每個 `PHAsset` 的狀態存在記憶體字典，並由「已同步集合」與設定共同決定：

- 讀取：`-[PHAsset mediaObjectState]` → `[TBPhotoLibraryHelper.sharedPhotoLibraryHelper mediaObjectStateForAsset:]`：
  - 無 asset → 回 5。
  - 有記錄：從 `_mediaObjectStateDictionary`（`TBMutableDictionary`）以 `localIdentifier`（`DataProvider.syncDBMigratedToLocalIDs==YES` 時）或舊制 `assetID` 為 key 取出，讀 `ObjectState` 欄位的整數。
  - 無記錄：用 `-[PHAsset isInSyncedSet]` 算預設值——在已同步集合 → 1；不在 → 2；算完立即寫回字典。
- 寫入：`-[TBPhotoLibraryHelper setMediaObjectState:asset:]` 把 `{ObjectState: n, Local_ID: 0/1, LocalIdentifier: …, PHAsset: asset}` 依新舊制 key 存進同一字典。
- 語意驗證（`DataProvider`）：
  - `-[DataProvider newAssets]`：predicate `objectState == 2 OR objectState == 4` → 未同步清單。
  - `-[DataProvider selectedAssets]`：predicate `objectState == 3 OR objectState == 4` → 已選取清單。
  - `-[TBPhotoLibraryHelper inverseStateForExistingState:]`：選取切換用互轉——1→3、2→4、3→1、4→2。
- 已同步集合（真正的持久真相）：
  - `DataProvider.syncedSet`（`NSMutableIndexSet`，以舊制 assetID 為索引）與 `syncedSetLocal`（`NSMutableSet`，存 localIdentifier），`syncDBMigratedToLocalIDs` 決定用哪個（`-[PHAsset isInSyncedSet]`、`-[PHAsset addToSycned]` 都照這個分岔）。
  - 選取／同步動作會「既寫狀態字典、又改集合」：`markSynced:`＝狀態 4→3、其他→1，並 `addToSycned`；`markSelectedNew:`＝狀態改 2 並 `removeFromSynced`。
- 持久化：`-[DataProvider saveDataProviderIncludingConfigurations:]` 把 `syncedSet`、`syncedSetLocal`（各自 `NSKeyedArchiver`）、`settings`、`libraryChangeToken` 打包成 binary plist，寫到 App Group（`group.com.touchbyte.PhotoSync`）容器內 `Library/Preferences/dataProvider.plist`（舊路徑 `NSLibraryDirectory/Preferences/dataProvider.plist` 會自動搬移）。`mediaObjectStateDictionary` 本身不落盤——重啟後由「是否在 syncedSet」重新推導（已同步→1，否則→2），選取狀態天然不保留。

## 6. 狀態怎麼畫到儲存格上

`-[PHCollectionViewBaseCell updateStateDisplay]`（重繪時點：`setAsset:`、`setImageViewRect:`、單擊、`refreshVisibleCells`）：

1. 讀 `asset.mediaObjectState`。
2. state 2 或 4 → `[TBThemeManager customizeLayer:type:10]`（藍框）；其餘 → `type:8`（灰框）。套在 `_imageView.layer`。
3. `coverView.hidden = (state < 3)` → 只有選取狀態（3、4）顯示 20% 黑覆蓋＋右下角 `flat_thumbselected` 勾勾。
4. `selectionIconView.hidden = quickLookMode`（快速瀏覽模式下藏選取勾勾）。
5. 收藏 ♥：`asset.isFavorite` 且 `TKDataSource.showFavoriteSymbol` 才顯示。
6. `_specialIconBanner`：影片／burst／RAW（`imageType` 1、2）→ 顯示底部黑條與對應符號；一般照片則整條隱藏並寫 log「rendered as regular Photo」。

## 7. 狀態改變與畫面更新路徑

- 手動選取：`handleSingleTap:` → `setInverseStateForAsset:`（1↔3、2↔4）→ 該 cell `updateStateDisplay` → `setToolBar:` 更新底部工具列數字。
- 全選／反選／區段選取（`selectAll:`、`deselectAll:`、`selectAllInSection:`…）同樣走 `setMediaObjectState:asset:`＋`refreshVisibleCells`。
- 手動標記（長按選單，字串來源「Mark all synced」「Mark selected as synced」「Mark sel. synced」「Mark as Synced」）→ `markSynced:`／`markSelectedSynced:`／`markSelectedNew:` → 狀態＋集合雙寫 → `refreshVisibleCells`。
- 真正的傳輸完成：`-[SyncController mediaObjectTransferDidFinish:]` 每傳完一檔 → `[phAsset addToSycned]` ＋ `saveDataProvider`（所以同步中途被砍也不會丟「已同步」紀錄）＋ `addToSentUsingConfiguration:`（歷史紀錄）；整批結束時對最後一個 asset 呼叫 `[TBPhotoLibraryHelper removeSyncSelectionForAsset:]`：
  - 設定 `keepSelections` 開啟且狀態是 3/4 → 不動（保留選取）。
  - 否則 → 狀態強制設 1（已同步），並 post `NSNotificationCenter` 通知 **"RefreshThumbnailDisplay"**。
- 首頁接收：`-[AlbumContentsViewControllerPhotoKit viewDidLoad]` 用 `addObserverForName:object:queue:usingBlock:`（main queue）註冊 "RefreshThumbnailDisplay" → block → `refreshVisibleCells` 把每個可見 cell 重跑 `updateStateDisplay`。這就是「傳完當下藍框變灰框」的更新鏈。
- 相簿資料庫變更（`PHPhotoLibrary` change observer）：
  - 新插入 asset → `setMediaObjectState:asset:2`（新＝未同步）。
  - 被刪除 asset → `removeMediaStateForAsset:` 清狀態。
  - 設定 `ModifiedAssetsAsNew` 開啟時，編輯日期晚於 `lastLibraryUpdateCheck` 的 asset → 狀態改 2＋`removeFromSynced`（編輯過＝重新視為未同步）。
  - 最後存 `libraryChangeToken`、`lastLibraryUpdateCheck`、`saveDataProvider`。

## 8. 主題與顏色常數

`+[TBThemeManager customizeLayer:type:]` 派發到當前主題；`TBPureTheme` 是空實作（無框）。`TBAutomaticTheme` 依系統外觀轉手給 FlatDark／FlatLight。

| 主題 | type 8（已同步） | type 10（未同步） |
| --- | --- | --- |
| TBFlatLightTheme | iPhone 2pt `#DDDEDB`（0.867, 0.871, 0.859）；iPad 3pt `#EAEBE8`（0.918, 0.922, 0.910） | iPhone/iPad 2/3pt `#21A7FB`（0.129, 0.655, 0.984） |
| TBFlatDarkTheme | iPhone 1pt 40% 灰（0.4, 0.4, 0.4）；iPad 3pt 白 | iPhone/iPad 2/3pt `#52BBFD`（0.322, 0.733, 0.992） |

其他相關主題圖（`imageWithType:`）：27＝`flat_newIcon`、36＝`flat_thumbselected`（選取勾勾）、41＝`flat_path-check`、57/60＝照片／影片 placeholder、37/38/39＝slomo／timelapse／burst 符號。

## 9. 驗證狀態與待確認事項

- 本份的流程、數值與格式均已逐項核對過原始程式行為；顏色值另以浮點常數核對。
- `flat_check.png` 在 bundle 根目錄存在，但未發現被首頁相關程式引用，用途不明。
- `flat_thumbselected` 的深色版是否為 asset catalog 內同名的 dark variant（dark 主題仍回同名，應是 catalog 變體），未逐項驗證。
- 狀態值 5 只確認是「asset 為 nil」時的回傳；是否有其他寫入 5 的路徑未窮舉。
- `handleSingleTap:` 在多選模式（`thumbDisplayMode != 0`）走 `endMultiSelectionForIndexPath:`，其內部細節未展開。
