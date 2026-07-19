# OMO100 macOS TFT／即時桌寵：Phase 0A、Phase 1A 與 Phase 1A+ 報告

- 日期：2026-07-17（Asia/Taipei）
- 範圍：Phase 0A 唯讀基線盤點、Phase 1A Windows driver 靜態逆向、Phase 1A+ Mac-only offline protocol archaeology，以及使用者另行授權後的 Mac USB descriptor snapshot
- 協定結論：**NEEDS-CAPTURE**
- Mac-only 主動測試 gate：**NO-GO**（沒有 Windows／VM capture，且尚無可安全白名單化的新 TFT 命令）
- 主要分析標的：`DeviceDriver.exe`，SHA-256 `6daed218dda5bedd5b25b6f46ccba4b6592af488407b367faed18c48571f2939`

## 1. 範圍與安全界線

本次只讀取專案、產生 `/tmp` 中間檔、編譯至 `/tmp`、執行不接觸 HID 的 `help`／`prepare`、靜態分析 Windows PE／DLL，以及分析公開的官方 WebHID driver 程式碼。沒有執行下列動作：

- 沒有向 OMO100 或鍵盤送出任何 HID report。
- 沒有執行 `upload` 或 firmware update。Phase 1A+ 離線分析完成後，使用者將鍵盤切至 USB 模式並另行授權執行一次唯讀 `list`；該命令只開啟 IOHIDManager、列舉 collection／report descriptor，沒有送 vendor feature/output command。
- 沒有開啟 WebHID 裝置，也沒有讓官方網頁連線 OMO100。
- 沒有掃描或猜測 `04 00...FF`。
- 沒有建立 reactive display、常駐程式、adapter 或 GUI。
- 沒有修改 `README.md`、計劃書、Swift 原始碼、`build.sh`、assets 或 binary。
- 沒有執行 `git init`、commit 或 push。

所有分析中間產物位於 `/tmp/omo100-phase-1a-20260717/`；專案內唯一新增檔案是本報告。

## 2. 結論摘要

### 已確認事實

1. Windows 有線 TFT 完整上傳函式位於 `0x004228c0`，其序列與 macOS 已知實機正確序列一致：
   `04 18` → `04 72 <slot> ... <block-low> <block-high>` → 4096-byte pages → `04 02`。
2. `04 72` 的 byte 2 是 `LCDViewList::GetCurSel() + 1` 所得到的 slot；byte 8–9 是 4096-byte block count（little-endian）。
3. Windows 主程式中另一條有 LCD 交叉證據的 USB feature 路徑位於 `0x00423880`：
   `04 18` → `04 28 ... byte[8]=01` → 含 slot 與本機日期時間的 feature report → `04 02`。
4. `0x00423880` 直接呼叫 `GetLocalTime`，並由 UI 的 `Time Syns` 操作呼叫；因此這是時間同步路徑，不是已知的 live frame／RAM preview／frame select。
5. 在 `DeviceDriver.exe` 的靜態交叉引用內，LCD slot／frame 選取、刪除與編輯函式沒有進入 USB feature wrapper；`Preview` 字樣本身也沒有導出一條新的 TFT HID command 路徑。
6. 沒有找到可只憑靜態證據安全進入 Phase 1C、並可合理視為 RAM preview、live frame、instant slot select、frame select 或 TFT play/pause 的命令。

### 有證據的推論

- `04 18` 與 `04 02` 是多種設定流程共用的 transaction begin／finalize，不是 TFT 專屬命令，也不能把 `04 02` 單獨推論成「切換顯示」。
- `04 72` 是持久 TFT bulk-upload 初始化，而不是單純 slot select：同一函式立即產生完整 RGB565 動畫資料、顯示 `Loading: %d%%`，並逐 block 寫入。
- `04 28` 是時間同步子命令或其準備命令；它值得在官方 Windows app 操作時被動 capture，但不值得直接對實機重放。
- Windows UI 的 `LED screen preview`／`Image preview`／`Preview` 很可能是 app 內本機預覽；目前主 EXE 靜態證據沒有顯示它會把即時 frame 傳到鍵盤。

### 尚待 capture 或實機驗證

- 點擊 LCD `Preview`、切換 slot、切換 frame、開始／停止預覽時，USB bus 是否完全無封包。
- `04 28` 及後續時間 report 的實際 feature GET 回傳內容。
- 官方 Windows app 的每個 4096-byte page read-back 是否實際回 `01 5A 02`；Windows wrapper 讀取後沒有驗證內容。
- 是否存在由 `mui.dll` 內部觸發、而未在 `DeviceDriver.exe` 直接顯示的 HID 路徑。現有 import／handle 架構使此可能性偏低，但本次沒有把 `mui.dll` 當第二個完整逆向標的。
- firmware update 路徑與本報告列出的 TFT 路徑是否共享更底層 transport；這不構成可測試 TFT 命令的證據。

## 3. Phase 0A：專案基線

### 3.1 工作樹狀態

交接資訊稱專案「目前不是 Git repository」，但 2026-07-17 實際唯讀檢查結果不同：

- `git rev-parse --is-inside-work-tree`：`true`
- branch：`main`
- HEAD：`35d2a9b Initial commit`
- `git status --porcelain`：分析開始前為空

本次沒有改動 Git metadata，也沒有 commit／push。此差異只是現況紀錄，不以交接敘述覆蓋實際檔案系統事實。

### 3.2 專案檔案與 hash

| 路徑 | 角色 | SHA-256 |
|---|---|---|
| `OMO100Tool.swift` | 單檔 CLI 主程式 | `a5a4db71665841de0f093e5046187f96a04c37eac50682099c7285cf45e0891c` |
| `build.sh` | Swift 編譯腳本 | `812d7f3dadabe56e56b0f6b21ed9fa21b0f5b945e6f09a5310ee7e0df91be3d1` |
| `omo100-tool` | 本機 arm64 build output（不納入公開 repository） | `652522a65fa24cd3c1ddc907b11f7c30cf531edb8ff5fb1a00c205ef5e0ca2c0` |
| 本機測試 GIF A | 已知正確輸入（不納入公開 repository） | `fe838a4ea1a58e8d7788130f2c7e1e75e94664c7df20299b4a6205870844a7fa` |
| 本機測試 GIF B | 另一個 96×160 asset（不納入公開 repository） | `4e8537719f966e9504bfd0b4b0b13b08dc1590a4e424c1357423c8b51c17d0f6` |

### 3.3 CLI 能力與編譯方式

CLI 命令：

- `list`：列舉 VID/PID `05AC:024F` 的 HID interfaces 與 report descriptors；原始碼中沒有寫 report。
- `prepare <input> <output>`：ImageIO 解碼、縮放／置中、只翻轉垂直軸、轉 RGB565 little-endian、按 100ms 左右展開 GIF 長 delay，輸出 block-aligned payload。
- `upload <payload> [--slot N] --yes-really-upload`：完整持久上傳；有明確危險旗標。

`build.sh` 的有效編譯命令為：

```sh
swiftc OMO100Tool.swift \
  -module-cache-path .build/module-cache \
  -framework IOKit \
  -framework CoreGraphics \
  -framework ImageIO \
  -o omo100-tool
```

為避免修改專案，實際重編譯的 output 與 module cache 都改放 `/tmp/omo100-phase-1a-20260717/`。重編後以同一輸入執行 `prepare`，產物與既有 binary 的產物 byte-for-byte 相同。

### 3.4 已知協定基線

原始碼、計劃書、已知實機結果與 Windows static path 共同支持以下基線：

- control interface：usage page/usage `0xFF13/0x01`，64-byte feature payload。
- screen interface：usage page/usage `0xFF68/0x61`，4096-byte output page；macOS 端讀 64-byte ACK。
- display：96×160，單 frame `96 × 160 × 2 = 30,720` bytes，RGB565 little-endian。
- payload header：256 bytes；byte 0 是 hardware frame count，後續 byte 是 20ms 單位 delay。
- max frames：192；Windows `config.xml` 同樣標示 `gif_headlength="256"`、`gif_maxframes="192"`、`width="96"`、`height="160"`。
- 完整持久上傳：`04 18` → `04 72` → 4096-byte pages → `04 02`。
- macOS 已知 page ACK：前三 bytes 必須為 `01 5A 02`。
- Windows `config.xml` 的 command delay 是 35ms，與現有 macOS uploader 相符。

## 4. 本機 payload 回歸基準

輸入：本機已驗證的 96×160 GIF（不納入公開 repository）

輸出只存於：`/tmp/omo100-phase-1a-20260717/known-good.omo100.bin`

| 欄位 | 值 |
|---|---|
| SHA-256 | `74fd6fef88a222aae33b0c5ba801fec1d64e512ad74d161bd751e838708996d6` |
| 原始來源 frame 數 | 3 |
| hardware frame 數 | 21 (`0x15`) |
| 未 padding 大小 | 645,376 bytes |
| block count | 158 (`0x009E`) |
| 完整檔案大小 | 647,168 bytes |
| 尾端 padding | 1,792 bytes，全部 `0xFF` |
| hardware delay bytes | `05` × 14、`06` × 1、`05` × 6 |
| 依 header 計算總週期 | 2,120ms |
| unique RGB565 frame image | 2 |

Header 摘要：

```text
offset 0x00: 15
offset 0x01..0x0E: 05 05 05 05 05 05 05 05 05 05 05 05 05 05
offset 0x0F: 06
offset 0x10..0x15: 05 05 05 05 05 05
offset 0x16..0xFF: FF
```

逐影格內容可濃縮成兩個 hash：

- hardware frames 1–14、16–21：`161cf867db4dfbcef21712f935b2a7caeb011403f04b7e4e32bc244ce78fb971`
- hardware frame 15：`804c0e176e8b38e53030c95044c5421ff589a529541318a970235f8d8e750641`

以上基準同時鎖定 frame 展開、header delay、RGB565 方向／內容與 block padding；未來若 converter 改動，應以完整 payload hash 與上述結構摘要一起回歸，不能只比檔案大小。

## 5. Phase 1A：Windows 靜態分析基線

### 5.1 標的身分

| 標的 | 摘要 |
|---|---|
| `DeviceDriver.exe` | PE32 GUI, Intel 80386，非 .NET；PE timestamp 2024-07-30 18:51:51；SHA-256 `6daed218...71f2939` |
| installer `OMO100 Driver-1.0.0.2(1).exe` | PE32 GUI, Intel 80386；SHA-256 `9768b317b060dc27950bacb64aeaadfacc05ad288d9ecee1cdb67fca1645a9cf` |
| `config.xml` | app version `Beta1.0.0.2`；有線 `MI_00`、2.4G receiver `MI_03`；有線 screen enabled，wireless screen disabled |

主要靜態工具：`file`、`shasum`、`objdump`、`rz-bin`、Rizin。沒有執行 Windows executable。

### 5.2 HID transport

`DeviceDriver.exe` 動態載入 `hid.dll`，並解析 `HidD_SetFeature`／`HidD_GetFeature`。關鍵 wrapper：

| 位址 | 功能 |
|---|---|
| `0x00451e00` | `HidD_SetFeature` wrapper |
| `0x00451ea0` | `HidD_GetFeature` wrapper |
| `0x0044f890` | 一般 feature transaction；Windows buffer 65 bytes（report ID + 64 protocol bytes） |
| `0x00451be0` | raw `WriteFile` wrapper |
| `0x00451cc0` | raw `ReadFile` wrapper |
| `0x0044fc90` | TFT 4096-byte page wrapper；Windows buffer 4097 bytes（report ID + page） |

Feature transaction 的確認處理：

- 先 `HidD_SetFeature`。
- 呼叫端把 read-back flag 設為 1 時，delay 後呼叫 `HidD_GetFeature`。
- Windows local buffer offset 4（扣除 report ID 後的 protocol byte 3）必須為 `0x01`，否則 wrapper 回傳失敗。

Page transaction 的確認處理：

- `0x0044fc90` 寫 4097-byte Windows report buffer。
- 寫入成功後，以 300ms timeout 呼叫 read wrapper，要求 4097 bytes。
- 此 wrapper **沒有檢查 read 回傳值或 ACK bytes，最後仍回傳 true**。因此 `01 5A 02` 的嚴格檢查是 macOS 已知實機路徑比官方 Windows wrapper 更強的保護，不能說 Windows static code 也驗證了該 signature。

## 6. TFT 候選命令詳表

以下位址是 PE image virtual address。Feature report 的「64 bytes」均指不含 report ID 的 protocol payload；Windows API 傳入的實際 buffer 是 65 bytes。

### C1 — `04 18`：transaction begin

- command bytes：`04 18`，其餘為 `00`。
- TFT call sites：
  - persistent upload：寫入 `0x00422df6`，呼叫 feature wrapper `0x00422e62`
  - time sync：寫入 `0x004238a3`，呼叫 feature wrapper `0x004238b8`
- report 方向／長度：control feature SET，64 bytes；接著 feature GET 65-byte Windows buffer。
- ACK／回傳：feature response protocol byte 3 必須為 `01`。
- UI／字串交叉證據：同時出現在 `Upload to keyboard`／`Loading: %d%%` 路徑及 `Time Syns` 路徑；也被其他非 TFT 設定流程重用。
- 推定用途：有強證據支持「一般 transaction begin／unlock」，但不知道是否還帶 mode switch 副作用。
- 分類：
  - RAM preview／live frame：無證據
  - slot select／frame select：無證據
  - play/pause：無證據
  - flash write：可包住 flash-write 流程，但自身不是足以確認的 write command
  - firmware update：無 TFT 路徑證據
- Phase 1C 安全性：**不可單獨測試**。

### C2 — `04 72 <slot> 00 00 00 00 00 <blocks-lo> <blocks-hi>`：TFT bulk-upload 初始化

- command bytes：

```text
byte 0..9: 04 72 SS 00 00 00 00 00 BL BH
byte 10..63: 00
```

- write／call site：
  - `0x00422e6d` 寫 `04 72`
  - `0x00422e76` 寫 byte 2 slot
  - `0x00422e82`／`0x00422e91` 寫 byte 8–9 block count
  - `0x00422eff` 呼叫 feature wrapper
- report 方向／長度：control feature SET，64 bytes；接著 feature GET。
- ACK／回傳：feature response protocol byte 3 必須為 `01`。
- UI／字串交叉證據：同一函式 `0x004228c0` 呼叫 `LCDViewList::GetCurSel`、`GetImageRGB565Data`，隨後逐 page 顯示 `Loading: %d%%`；語系另有 `Upload to keyboard`、`Save data and upload boot animation`、`Animation Upload`。
- 推定用途：**持久 TFT bulk upload 的 slot／block-count 宣告**。slot 欄位已確認，但整體命令不是輕量 slot select。
- 分類：
  - RAM preview／live frame：反證較強；後面必接完整 bulk pages
  - slot select：含 slot，但用途是 upload target，不是 instant display select
  - frame select／play/pause：無證據
  - flash write：高度吻合，且已有既有實機持久化結果
  - firmware update：無證據；payload 結構明確是 256-byte header + RGB565 frames
- Phase 1C 安全性：**不可作為即時顯示候選；禁止重放**。

### C3 — 4096-byte page stream：TFT bulk data（非 `04 xx` feature command）

- data：每次 4096 bytes，Windows wrapper 前置一個 report ID byte。
- call site：upload loop 內 `0x00422fb3` → `0x0044fc90`。
- report 方向／長度：screen output `WriteFile`，4096 protocol bytes／4097 Windows bytes；接著 `ReadFile`。
- ACK／回傳：Windows 最多等 300ms，但不驗證內容；macOS 已知正確 ACK 是 `01 5A 02`。
- UI／字串交叉證據：每 block 更新 `Loading: %d%%`；來源是 `GetImageRGB565Data`。
- 推定用途：持久動畫 payload 的 bulk page transfer。
- 分類：flash write 高；RAM preview、live frame、frame select、play/pause 無證據；不是 firmware image path。
- Phase 1C 安全性：**禁止重放**。

### C4 — `04 02`：transaction finalize／apply

- command bytes：`04 02`，其餘為 `00`。
- TFT call sites：
  - persistent upload：寫入 `0x0042305f`，呼叫 `0x004230cb`
  - time sync：寫入 `0x00423982`，呼叫 `0x00423997`
- report 方向／長度：control feature SET，64 bytes；接著 feature GET。
- ACK／回傳：feature response protocol byte 3 必須為 `01`。
- UI／字串交叉證據：同時收尾 upload 與 Time Syns；也被其他非 TFT 設定流程重用。
- 推定用途：一般 finalize／commit／apply。因為它也收尾 time sync，不能只憑 upload 結果命名為「flash commit」。
- 分類：可能讓先前 transaction 生效；沒有獨立的 RAM preview、slot/frame select、play/pause 或 firmware-update 證據。
- Phase 1C 安全性：**不可單獨測試**，未知前態可能使其產生副作用。

### C5 — `04 28 ... byte[8]=01`：Time Syns 準備命令

- command bytes：byte 0–1 `04 28`，byte 8 `01`，其餘 `00`。
- write／call site：`0x004238cd` 寫 `04 28`，`0x004238d6` 寫 byte 8，`0x004238e6` 呼叫 feature wrapper。
- report 方向／長度：control feature SET，64 bytes；接著 feature GET。
- ACK／回傳：feature response protocol byte 3 必須為 `01`。
- UI／字串交叉證據：函式 `0x00423880` 由 `0x0043535b` 的 Time Syns handler 呼叫，下一步直接呼叫 `GetLocalTime`。
- 推定用途：時間同步準備／選擇時間資料類型；不是顯示 frame 命令。
- 分類：
  - RAM preview／live frame：無證據
  - slot select：命令本身沒有 slot；slot 在下一個 report
  - frame select／play/pause：無證據
  - flash write：是否持久保存 RTC/metadata 尚不明
  - firmware update：無證據
- Phase 1C 安全性：**只值得 Phase 1B 被動 capture，不可主動重放**。

### C6 — Time Syns data feature report

- command/data bytes template：

```text
00 SS 5A YY MM DD hh mm ss 00 dow 00 ... 00 AA 55
```

其中 `SS = LCDViewList::GetCurSel() + 1`；`YY = local year % 2000`；最後 `AA 55` 位於 byte 62–63。

- construction／call site：`0x004238ef` 呼叫 `GetLocalTime`；`0x0042390b..0x00423960` 組 report；`0x0042396d` 呼叫 feature wrapper。
- report 方向／長度：control feature SET，64 bytes；接著 feature GET。
- ACK／回傳：feature response protocol byte 3 必須為 `01`。
- UI／字串交叉證據：`Time Syns`、`GetLocalTime`、current LCD selection。
- 推定用途：向所選 LCD slot 寫入／同步本機日期時間 metadata。
- 分類：含 slot 但不是顯示 slot select；與 RAM preview、live frame、frame select、play/pause、firmware update 均無證據；是否 persistent metadata 待 capture／重啟驗證。
- Phase 1C 安全性：**不可重放**。

## 7. TFT 路徑完整性與排除證據

### 7.1 主 EXE 中與 TFT 相交的 feature paths

對 `0x0044f890` 的 41 個 call sites 做交叉引用，再與 `LCDViewList` imports／TFT UI handler 相交，得到兩個 USB TFT 函式：

- `0x004228c0`：完整有線 TFT upload
- `0x00423880`：有線 Time Syns

另有 `0x00423160` 與 `0x004239b0` 是 2.4G transport 的 upload／time alternative，使用 `0C 10`／`03 7F` 等另一套 framing 並走 `0x0044ffb0`；`config.xml` 對 wireless mode 標示 screen disabled。它們可作為語意交叉證據，但不是本次有線 `04 xx` 候選。

### 7.2 其他 literal `04 xx` family

全 PE 的 immediate scan 找到下列 command family：

```text
04 02, 04 13, 04 15, 04 17, 04 18, 04 19, 04 20,
04 23, 04 28, 04 2B, 04 72, 04 F0, 04 F5
```

除了共用 begin/finalize `04 18`／`04 02` 外，只有 `04 72` 與 `04 28` 位於上述兩個 TFT 函式。其餘 family 位於 `0x00413d60`、`0x00418300`、`0x00427ed0`、`0x0042afb0`、`0x0042b1d0`、`0x0042d940`、`0x00432c30`、`0x00434460`、`0x0044c2c0`、`0x0044c3d0` 等其他設定路徑，沒有 `LCDViewList`／TFT UI 交叉證據。本次不替它們猜用途，也不把鄰近 command number 當候選。

### 7.3 Preview、slot、frame 與 play/pause

- 語系確實包含 `LED screen preview:`、`Image preview:`、`Preview`、`Frames`。
- LCD slot／frame 選取及刪除的主 EXE call sites（例如 `LCDViewList::SetCurSel`、`ImageViewList::SetCurSel`、`LCDViewList::DeleteItem`）沒有呼叫 `0x0044f890` 或 TFT page wrapper。
- `CGifPicture::SetRunState` 的兩個主 EXE xrefs 用於 `main_bkg.gif` 與 `loading.gif`，不能解讀為鍵盤 TFT play/pause。
- 語系中的一般 `Click to play` 與 keyboard multimedia mapping 也不能當成 TFT command 證據。

因此，**目前找不到 instant slot select、frame select、play/pause、RAM preview 或 live frame command**。這是「沒有找到靜態證據」，不是「已證明 firmware 絕對沒有這些能力」。

## 8. 安全候選與 Phase gate

### 最有希望的候選

- **Phase 1B capture 候選：官方 Windows app 的 LCD `Preview` 操作。** 最有價值的結果可能是證明它完全不產生 USB traffic；若有 traffic，才能從真實封包建立 whitelist。
- **命令層 capture 候選：`04 28` Time Syns path。** 它是唯一除完整 upload 以外、具有直接 TFT UI／`LCDViewList` 交叉證據的 USB feature 子命令；但它的語意已高度指向時間同步，不是 live display。
- **Phase 1C 主動候選：目前沒有。** `04 72` 是完整持久 upload；`04 18`／`04 02` 是具未知前態的通用 transaction bracket；`04 28` 會修改時間／metadata 的可能性高。

### Phase 1A 結論：NEEDS-CAPTURE

不是 `GO`，因為沒有足夠證據允許主動送出任何新命令；也不是 `NO-GO`，因為官方 UI 操作的 USB capture 尚未完成，仍可能揭露由事件路徑或 DLL 間接觸發的安全命令。

在 capture 完成並建立 exact whitelist 以前，不應進入 Phase 1C，不應測試鄰近 command，也不應用已知 persistent uploader 模擬即時狀態切換。

## 9. 下一階段所需條件

### 使用者操作／硬體

- 一台 Windows 實機優先；若用 VM，必須讓 OMO100 USB 裝置完整且獨占 passthrough，避免 host driver 混入。
- OMO100 以 USB 有線模式連線，對應 `VID 05AC / PID 024F / MI_00`。
- 安裝並使用同版官方 app／driver `1.0.0.2`。
- 安裝 USBPcap + Wireshark，capture filter 限定 OMO100 裝置，避免鍵盤其他敏感 traffic。
- 準備可犧牲的 TFT slot，並先人工記錄目前各 slot 內容；任何可能改寫 device 的官方操作都由使用者明確觸發。

### 建議 capture 矩陣

每個動作各自開始／停止一份 capture，記錄準確時間，不把多個操作混在同一段：

1. app 啟動後靜置 10 秒，建立 idle baseline。
2. 只點不同 LCD slot，不按 Upload。
3. 只切換不同 frame，不按 Upload。
4. 點 LCD `Preview` 開始、等待數秒、停止。
5. 修改 frame delay／複製 frame，但不 Upload。
6. 點 `Time Syns` 一次，取得 `04 18`／`04 28`／time data／`04 02` 的真實 request/response。
7. 對 Delete 先 capture「出現確認框後取消」；若要 capture 確認刪除，使用可犧牲 slot 並先取得使用者同意。
8. 最後才用已知正確 payload 做一次官方完整 Upload，作為 `04 72` 與 page ACK 的對照 capture；這是下一階段的人工參考操作，不是本 session 已執行的動作。

### 進入 Phase 1C 前的必要證據

- 精確 interface／endpoint／report type。
- request 完整 bytes、固定欄位與變動欄位。
- response／ACK 完整 bytes及 timeout 行為。
- 一個 UI action 對一組封包的可重現映射，至少重複兩次一致。
- 確認命令不進入 bootloader、firmware update、flash erase／write 或 persistent upload 路徑。
- 只允許 exact whitelist；禁止 range scan、鄰號猜測與未知前態下的 `04 02`。

## 10. Phase 1A+：Mac-only offline protocol archaeology

### 10.1 方法與新增標的

Phase 1A+ 不執行 Windows、Windows VM 或任何硬體傳輸。分析方法包括：

- 補完 `DeviceDriver.exe` LCD UI event dispatcher、menu dispatcher、handler 與所有 HID wrapper 的靜態可達性。
- 將 `mui.dll` 的 `ImageView::SetImagePreviewMode(bool)` 當成第二個完整標的逆向，排除 DLL 內隱藏 transport callback。
- 盤點 extracted app 的 firmware／screen 檔案與 updater path；不執行 updater。
- 搜尋同 VID/PID、同尺寸 TFT 的公開同平台程式碼，並下載官方 EPOMAKER WebHID driver JavaScript 至 `/tmp` 做離線分析。
- 沒有使用函式模擬器：Preview target 的兩層 call graph、函式內容與 import closure 已經是確定性的本機 UI 路徑；在此情況下模擬不會增加 protocol 證據。

新增分析標的：

| 標的 | 來源／身分 | SHA-256 |
|---|---|---|
| `mui.dll` | Windows app 內的 MUI library | `ccd915849010bbc27735c1bdd9f786449ce72febb88d0e845f6bfce85a330f19` |
| `app.626d2e32.js` | 2026-07-17 取得的 EPOMAKER 官方 WebHID app bundle；中間檔名 `epomaker-app.js` | `366dbd6e258a926846c999590d35394a07ec805d1b04abc00bbd76dae584b094` |
| `GamingKeyboard106/defaultGif.json` | 官方 WebHID 的 96×160 WK98 default GIF 資料 | `f9b6357cb29daf49af66f01f513d95e2ffcac1a50204dc85e5e5a809625f96fc` |

官方來源：

- `https://epomaker.driveall.cn/`
- `https://epomaker.driveall.cn/static/js/app.626d2e32.js`
- `https://config.driveall.cn/gif/GamingKeyboard106/defaultGif.json`

以上網路來源只作 sibling／cross-version 靜態證據，不把目前網站程式碼視為 OMO100 firmware 的已確認協定。

## 11. Windows LCD UI 與 Preview 閉環

### 11.1 UI event 對應

LCD click dispatcher 的關鍵 control ID／handler：

| control ID | handler | 靜態行為 |
|---|---:|---|
| `0x13E` | `0x00424540` | 新增 LCD item，本機 model／file 操作 |
| `0x13F` | `0x00424790` | 匯入 GIF，本機 decoder／model 操作 |
| `0x140` | `0x00424AF0` | 刪除 LCD item，本機 model 操作 |
| `0x147` | `0x00424D20` | 關閉 Image Preview／回到 Editing |
| `0x149` | `0x00424D90` | 開啟 Image Preview |
| `0x151` | `0x004255E0` | 新增文字 |
| `0x153` | `0x00425840` | 新增 frame |
| `0x156` | `0x00425C70` | 刪除 frame |
| `0x168` | `0x00426700` | 將 editor frame 存回 `LCDViewList::SetFrameData`，仍是本機 model |

change dispatcher 中，`0x13D → 0x004242C0` 是 LCD slot 選取，`0x146 → 0x00424F20` 是 frame 選取，`0x14A → 0x004252A0` 是 frame delay。這些 handler 都沒有到達 USB feature、raw page 或 2.4G wrapper。

### 11.2 `Preview` 已確認是本機 UI

`0x00424D90` 的完整行為：

1. 呼叫 `ImageView::DeleteAllItems()`。
2. 從 `ImageViewList::GetImageViewItems()` 取得本機 frame vector。
3. 逐項呼叫 `ImageView::AddString(...)` 複製到 preview control。
4. 呼叫 `ImageView::SetImagePreviewMode(true)`（call site `0x00424E87`）。
5. 更新按鈕顏色、重繪 control，並停用 editor controls。

`0x00424D20` 只呼叫 `SetImagePreviewMode(false)`（call site `0x00424D2B`）、更新按鈕與重新啟用 controls。

`mui.dll` export `MUI::ImageView::SetImagePreviewMode(bool)` 位於 `0x1002A710`，其全部實作為：

- 將 bool 存到 object offset `+0x164`。
- 由本機 vector 算出 frame count，存到 `+0x16C`。
- 將 current frame index `+0x168` 歸零。
- 呼叫 `GetTickCount()`，將 tick 存到 `+0x170`。
- return；沒有 callback、檔案寫入或 HID I/O。

`mui.dll` 沒有 import `hid.dll`、SetupAPI、`ReadFile` 或 `DeviceIoControl`。其 `CreateFileW`／`WriteFile` 交叉引用只屬於 `MUI::MRender::SaveBitmapToFile`，與 Image Preview 無關。

因此可把原 Phase 1A 的「很可能是本機預覽」提升為：

> **在本次分析的 Windows binaries 內，LCD `Preview` 已確認是 app 本機動畫預覽，不是 RAM preview 或 live-frame transport。**

這項確認限於被分析的 `DeviceDriver.exe`／`mui.dll` 版本，不宣稱 device firmware 永遠沒有未暴露能力。

## 12. Transport reachability 完整性

### 12.1 USB wrapper closure

全主 EXE 交叉引用結果：

- 一般 feature wrapper `0x0044F890` 有 41 個直接 call sites；和 TFT/LCD handler 相交者只有：
  - `0x004228C0`：persistent TFT upload
  - `0x00423880`：Time Syns
- TFT page wrapper `0x0044FC90` 只有 `0x004228C0` 呼叫。
- 其他 feature wrappers：
  - `0x0044FA80` 只有 `0x00427ED0`、`0x00432C30` 呼叫。
  - `0x0044FD60` 只有 `0x0042AFB0` 呼叫。
- low-level `HidD_SetFeature` `0x00451E00` 的 callers 只有上述三個 feature wrappers；`HidD_GetFeature` 同樣封閉在這三個 wrappers。
- raw `WriteFile` `0x00451BE0` 的 callers 只有 `0x0044FC90`、`0x0044FFB0`、`0x00450150`；raw `ReadFile` 亦沒有 LCD Preview handler caller。
- 2.4G wrapper `0x0044FFB0` 的 TFT 交集仍只有 `0x00423160` upload 與 `0x004239B0` time。
- `ImageView::SetImagePreviewMode` 在主 EXE 恰有兩個 xrefs：`0x00424D20` 與 `0x00424D90`。

### 12.2 TFT menu action closure

| action | handler | 用途／transport |
|---|---:|---|
| `0x0F` | `0x00435310` | `SaveGIFImageFile`，本機匯出 |
| `0x10` | `0x004228C0`／`0x00423160` | USB／2.4G 完整持久 upload |
| `0x11` | `0x00434E30` | `LoadGIFImageFile`，本機匯入 |
| `0x13` | `0x00435350` → `0x00423880`／`0x004239B0` | Time Syns |
| `0x14` | `0x00435740` | driver software updater |
| `0x15` | `0x004359D0` | firmware updater download／extract／execute |

extracted app 內沒有 `.bin`、`.hex`、`.fw`、`.rom` 或其他可辨識 firmware image；`config.xml` 的 firmware file／URL 欄位為空。`0x004359D0` 只準備 `FirmwareUpdateTool.zip`、下載、解壓、`ShellExecute` 並退出，沒有提供可離線分析的 firmware payload，也不構成 TFT command 證據。

## 13. 官方 WebHID 同平台證據

### 13.1 精確 VID/PID 與尺寸交叉

官方 EPOMAKER WebHID registry 的 `womier_jx` 群組包含：

```text
vendorId 1452 = 0x05AC
productId 591 = 0x024F
name = Womier WK98
isShowScreen = true
screenConfig = GamingKeyboard106 / w96h160 / 96 × 160
```

這與 OMO100 的 `05AC:024F` 及 `96×160` 完全相同，是目前最強的公開 sibling-platform 證據。官方 WK98 default GIF 也是 `96×160`、120 frames。

但 Web app 寫 TFT 時尋找 usage page `0xFF67`；現有 OMO100 macOS 基線的 screen interface 是 `0xFF68/0x61`。此外 Web protocol framing、ACK 與 delay encoding 都不同。因此「相同 VID/PID／尺寸」只能證明 OEM／firmware lineage 很近，不能證明 packet 可互換。

### 13.2 S1 — `AA 50`：WebHID 完整 TFT upload

- command bytes／4104-byte output report layout：

```text
00: AA 50
02..03: page index, little-endian
04..05: ceil((pixelBytes + 256) / 4096), little-endian
06..07: 0x650000 / 4096 = 0x0650, little-endian → 50 06
08..4103: 4096-byte page payload
```

- source sites：builder `buildPkt_TFT` at bundle byte offset `1,914,759`；`saveGif` at `2,993,930`；send path around `2,995,861`。
- report 方向／長度：WebHID `sendReport(0, packet)`，output report ID 0，4104 bytes；選擇同 product ID 且 collection usage page `0xFF67` 的 HID device。
- ACK：input report 前兩 bytes `55 41` 才送下一 page；沒有 finalize command。
- UI／字串交叉證據：`GifEditor.saveGif`、upload progress、`screen_text13/14`。
- payload：第一 page 先放 256-byte header，再放 3840 pixel bytes；後續 page 接續 RGB565 little-endian pixels。header byte 0 是 frame count，delay byte 寫成 `5 * editorDelay`。其 delay 單位與 OMO100 已確認的 20ms header 語意不能視為相同。
- 推定用途：另一代／另一 interface 的**完整 persistent TFT upload**，不是 RAM preview。
- 分類：flash write／persistent upload 高；live frame、frame select、play/pause 無證據；不是 firmware update。
- OMO100 安全性：**NO-GO**。不能把 sibling protocol 直接送往 OMO100，且它本身就是完整 bulk write。

### 13.3 S2 — `AA 51`：WebHID built-in image bank select

- command bytes：4104-byte zero-filled output report，byte 0–1 `AA 51`，byte 8 是 `curreBuiltIn`。
- source site：`changeBuiltIn` at bundle byte offset `2,993,649`；packet construction around `2,993,829`。
- report 方向／長度：WebHID `sendReport(0, packet)`，4104 bytes，使用 TFT output device。
- ACK／回傳：該函式沒有等待或驗證 ACK；之後仍執行完整 `AA 50` upload。
- UI／字串交叉證據：只有 `screenConfig.builtInCount > 1` 才呼叫。WK98 的 config 沒有 `builtInCount`，component 預設值是 1，所以 WK98／相同 VID/PID 路徑不會送 `AA 51`。
- 推定用途：選擇多個內建 TFT bank 的 upload target，不是一般 user slot／frame select，也沒有證據能單獨立即切換顯示。
- 分類：可能涉及 bank select；RAM preview、live frame、frame select、play/pause、firmware update 均未支持；緊接 flash write。
- OMO100 安全性：**NO-GO**。它不是相同 VID/PID branch 的實際命令，且沒有 OMO100 Windows binary 交叉證據。

### 13.4 S3 — WebHID `Preview` 與 Time

- Web `GifEditor.handlePreview` at bundle byte offset `2,991,471` 只把本機 frames 交給 GIF encoder，設定 `previewGifUrl`；沒有 `sendReport`。這與 Windows MUI Preview 的本機語意獨立吻合。
- Web time path at `2,999,354` 建立 `AA 34 ...` output report，內容含 `5A 01 5A`、日期時間與星期。它和舊 Windows `04 28`／time-data path 具有語意親緣，但 framing 不同，且不屬 live display 候選。

## 14. Phase 1A+ 候選總表

| 候選 | OMO100 證據層級 | RAM/live | slot/bank select | frame select | play/pause | flash write | firmware update | gate |
|---|---|---|---|---|---|---|---|---|
| Windows `Preview` (`0x424D90` → MUI `0x1002A710`) | 已確認本機 UI | 否 | 否 | 只讀本機 vector | 本機 timer only | 否 | 否 | 不需硬體測試 |
| `04 72` + pages | 已確認 OMO100 | 否 | upload target slot | 否 | 否 | 是 | 否 | 禁止重放 |
| `04 28` + time report | 已確認 OMO100 static semantic | 否 | report 帶 slot metadata | 否 | 否 | 未知 metadata persistence | 否 | 不主動測試 |
| Web sibling `AA 50` | 同 VID/PID／尺寸，非 OMO protocol confirmation | 否 | 無 | 否 | 否 | 是 | 否 | NO-GO |
| Web sibling `AA 51` | 非 WK98 branch 實際命令 | 無證據 | built-in upload bank | 無證據 | 無證據 | 緊接 write | 否 | NO-GO |
| Web sibling `AA 34` time | sibling semantic only | 否 | 否 | 否 | 否 | metadata 未知 | 否 | NO-GO |

## 15. 事實、推論與待驗證的最終分界

### 已確認事實

- Windows `Preview` 在 `DeviceDriver.exe` 與 `mui.dll` 內完全是本機 UI／timer 路徑。
- Windows TFT transport closure 仍只有完整 upload 與 Time Syns；沒有第三條 hidden LCD feature/page path。
- 官方 WebHID registry 確實列出 `05AC:024F`、96×160、screen-enabled 的 Womier WK98。
- 該 Web app 的 TFT write 是 `AA 50` 4104-byte pages、`55 41` ACK；Preview 仍是本機 GIF encoder。
- Web `AA 51` 只有 `builtInCount > 1` 才使用；WK98 config 不啟用。

### 有證據的推論

- OMO100、Womier WK98 與其他同平台鍵盤高度可能共享 OEM／TFT data pipeline lineage。
- 256-byte header、4096-byte page 與 RGB565 little-endian 的重合，顯示新舊 protocol 很可能包裝同類型的 flash animation object。
- `AA 50`、`AA 51` 與 `55 41` 很可能屬於另一代 firmware 或另一 HID interface，不應翻譯成鄰近 `04 xx` 命令。
- 官方 app 沒有 live preview UI transport，降低 firmware 已公開 live-frame 命令的可能性，但不能證明 firmware 絕對不存在未公開 command。

### 尚待 capture 或 firmware 驗證

- USB descriptor 問題已由使用者授權的 Mac `list` 解決：目前這台 OMO100 沒有暴露 `0xFF67` collection 或 4104-byte output report。
- OMO100 firmware 是否接受 `AA 50` family。基於安全界線，**不得為了回答這題而主動送出**。
- OMO100 是否有未被官方 Windows UI 使用的 RAM framebuffer／live-frame command；只有 firmware image 或被動 capture 才可能提供強證據。

## 16. Phase 1A+ 結論與 Mac-only 下一步

### 最終判定

- **協定研究：NEEDS-CAPTURE**。新命令若要升格為 OMO100 已確認協定，仍需要真實 request/response 或 firmware code。
- **在「只有 Mac、完全不考慮 Windows 實機／VM」條件下進入 Phase 1C 主動未知命令測試：NO-GO。** 目前沒有安全候選；`AA 50` 是完整 write，`AA 51` 不是 WK98 branch 實際命令，`04 72` 已知是持久 upload。
- **Phase 1A+ offline archaeology：GO／已完成。** 它成功把 Preview 從「推論」提升為「已確認本機 UI」，並找到最接近的公開 sibling protocol，但沒有產生可安全送往 OMO100 的 live-display whitelist。

### Mac-only 還能做的安全探索（需另行明確授權）

1. **唯讀 descriptor snapshot：已完成。** 使用者把 OMO100 切至 USB 模式並明確授權後執行現有 `list`；結果記錄於下節。
2. **取得 firmware/update package 後繼續純離線逆向。** 最理想是官方 `FirmwareUpdateTool.zip`、其中 firmware blob 或另一版 Windows／Web driver；不執行 updater，只做 hash、解包、字串、call graph 與 diff。
3. **建立公開 sibling corpus。** 收集同 `05AC:024F` 或 `GamingKeyboard106/w96h160` 的官方 driver 版本，diff `AA 50/51`、base address `0x650000`、ACK 與 screen config，尋找 protocol evolution；中間檔仍只放 `/tmp`。
4. **Mac 被動 USB capture，只觀察已知唯讀行為。** 可在執行 `list` 時記錄 descriptors/control enumeration，不能把「瀏覽器連線官方 WebHID app」視為唯讀，因為 app 初始化可能自動送設定命令。
5. **若未來明確允許一次已知持久 upload，** 可在 Mac 上 capture 現有、已實機驗證的 `04 18/04 72/pages/04 02` 作為 transport ground truth；這仍不會發現 live command，而且不屬本 session 安全範圍。

### 不建議的 Mac-only 探索

- 不要讓 EPOMAKER WebHID app 直接連 OMO100；它以 exact VID/PID 接受裝置，初始化及 apply 行為可能寫入鍵盤。
- 不要測 `AA 50`、`AA 51`、`AA 34`，也不要將它們機械映射到 `04 xx`。
- 不要用 macOS IOKit 掃描 command range、鄰號或未知 feature report。
- 不要以已知 persistent uploader 做高頻切換；它仍是 flash write path。

## 17. 使用者授權的 Mac USB descriptor snapshot

### 操作邊界

- 鍵盤由使用者切換至 USB 有線模式。
- 只執行 `./omo100-tool list`。
- 沒有呼叫 `IOHIDDeviceSetReport`、沒有 feature/output report、沒有 upload。
- sandbox 內第一次開啟 IOHIDManager 被 macOS 權限拒絕；取得該次唯讀列舉授權後在 sandbox 外重跑成功。失敗的第一次也沒有取得 device handle 或送 report。

### 已確認結果

```text
找到 2 個 OMO100 HID collection：
[1] 螢幕資料通道 — SONiX / OMO100 keyboard
    usagePage=0xFF68 usage=0x61 input=64 output=4096 feature=0
[2] 控制通道 — SONiX / OMO100 keyboard
    usagePage=0xFF13 usage=0x01 input=64 output=64 feature=64
```

因此可確認：

- OMO100 USB 模式只有兩個被 VID/PID filter 命中的 HID collections。
- TFT bulk path 是 `0xFF68/0x61`、4096-byte output、64-byte input ACK，與現有 macOS uploader 基線一致。
- control path 是 `0xFF13/0x01`，64-byte input/output/feature。
- **不存在 `0xFF67` collection，也不存在 4104-byte output report。**

### 對 sibling protocol 的影響

EPOMAKER WebHID `AA 50/51` packet 固定是 4104 bytes，並明確尋找 `0xFF67` collection。OMO100 的實際 descriptors 同時不滿足這兩個必要條件。因此：

- `AA 50/51` 可保留為 OEM lineage／protocol evolution 證據。
- 它們不能透過 OMO100 現有 screen interface 原樣傳送；4096-byte report 也容不下 8-byte framing 加 4096-byte page。
- 不應嘗試截斷、拆包、改送 control interface，或猜測 `AA` family 的 feature-report 版本。

這使 Mac-only 主動未知命令 gate 維持 **NO-GO**，而且比 descriptor snapshot 前更確定；後續最有資訊價值的來源已轉為 firmware image、另一版官方 binary 或既有已知操作的被動 capture，而不是繼續探測 HID command。

## 18. Phase 1A+ 延伸：官方 sibling driver／firmware corpus

### 操作邊界

- 本節只下載、解包與反組譯官方公開檔案；沒有啟動任何 Windows installer、driver 或 updater。
- 沒有對 OMO100 開啟 device handle，也沒有送 HID report、執行 upload 或 firmware update。
- 所有下載檔、解包內容、firmware binary 與反組譯輸出都位於 `/tmp/omo100-phase-1a-20260717/`。
- sibling 型號只作 protocol lineage 與 firmware-side control-flow 證據；**不得把它們的 firmware、位址或命令直接套用到 OMO100。**

### 官方檔案盤點

| 官方檔案 | bytes | SHA-256 | 離線結果 |
|---|---:|---|---|
| `Womier_X98.exe` | 2,028,364 | `1b3705005b614ce5ca54ad81bcf1fc5fca9e67d43f5d7d4132096ba9c297068f` | BYCOMBO `OemDrv.exe` 系列；沒有 HFD/Tongchi TFT command lineage |
| `Womier_SK80_Driver_V1.0.rar` | 5,499,943 | `bf5edfbff95d3cd99f819c2649b86085bd49043f94f3c2142e80eebf49a5025c` | 內含 HFD/Tongchi `DeviceDriver.exe`；`device.xml` 為 `05AC:024F` |
| `Womier_M87_Setup_V1.0_20240930.exe` | 1,508,715 | `c0862dc12e097c3eb08fd1799a7a0a41a82d40ada59d781e7469eb47403b7d5a` | BYCOMBO `OemDrv.exe` 系列；未提供同源 TFT 證據 |
| `WOMIER_M87_Pro_Driver.exe` | 6,736,019 | `7478decc50609d4de2a03e53910e8de8167ffcc7c823fe0bfd09fd2f44b0e52e` | 內含 `05AC:024F` HFD/Tongchi driver、240×135 screen layout，以及一個獨立 firmware updater |

以上來源來自 Womier 官方 software 頁面的下載連結。下載 URL 與檔名屬網站當下內容；hash 才是本次分析 corpus 的固定識別。

## 19. SK80：與 OMO100 持久 TFT upload 的 code-level homolog

SK80 `DeviceDriver.exe`：

- size：1,689,880 bytes
- SHA-256：`762ae0ae47cb84023a0e980d6b9cfed5b40c7f79d7a70fe27c5ad6c8d8c47249`
- `device.xml`：`vid="05AC" pid="024F"`，identify `RKGK890`
- TFT upload 函式：`0x004234D0`；UI call site `0x00437233`

| 階段 | SK80 位址 | OMO100 homolog 位址 | 證據 |
|---|---:|---:|---|
| begin `04 18` | `0x00423923` | `0x00422DF6` | 同型 x86 immediate write 與同一 upload control flow |
| init `04 72` | `0x00423976` | `0x00422E6D` | 隨後進入 4096-byte page loop |
| page write | `0x004239B0..0x00423A56` | OMO wrapper `0x0044FC90` | 4096-byte page 與逐頁進度處理 |
| finalize `04 02` | `0x00423A80` | `0x0042305F` | page loop 完成後的同型 finalize |

這是比「同 VID/PID」更強的靜態證據：SK80 與 OMO100 的 `DeviceDriver.exe` 使用同一個 HFD/Tongchi TFT persistent-upload 實作家族。它同時再次排除把 `04 72` 解讀成廉價 slot select 或 live-frame command；call site 仍是完整素材編碼、page loop 與 `Loading` UI。

SK80 app 內沒有可辨識的 `.bin`／`.hex` firmware payload，upgrade URL 亦為空。binary 內雖含 SONiX ISP programmer 字串，但那是 firmware-update tooling，不是 TFT command 的交叉證據，也不形成安全測試候選。

## 20. M87 Pro updater 與 firmware blob：嚴格隔離的 sibling 證據

M87 Pro `DeviceDriver.exe`：

- size：1,672,704 bytes
- SHA-256：`9bc01aad6c627e8f4e8d529d2649740b5e8605d46b5a3090980dd96e19b28c74`
- wired config：`05AC:024F`, `MI_00`
- screen config：240×135、wired only
- `04 18`／`04 72`／`04 02` immediate 位址：`0x00423036`／`0x004230AD`／`0x0042329F`

installer 另帶一個檔名明確標示 **F98 Pro** 的 updater：

```text
SI-2195-1.14 F98 Pro 5040135單節4000mAh_HFD80CP100_V1.20_20240111_0x4ACA.exe
size: 2,234,368 bytes
SHA-256: f5c93e7ae69036c869214026e57edfa3016aed523060d3ff629da19c00ae3d9b
```

其 resources 內可離線取出兩份不同內容：

| artifact | size | SHA-256 | 證據 |
|---|---:|---|---|
| RCDATA `4000` ARM blob | 262,144 | `eca35d5ad27c7d9092b3a2f8ea80b8c6572ea0baede7912e5dc0e8f486208c84` | 含 `AULA-F98Pro-$`、`USB Cable!` |
| RCDATA `4011` ZIP | 162,502 | `0711b2dc3cdee3a117d8a9e1053451d1a70d447bbbc9dfb1f52f9ef09bcd9ea5` | 含 updater settings 與 `SN32F290.hex` |
| checksum-valid Intel HEX 轉出的 `SN32F290.bin` | 262,144 | `880cab046381e483678ec4b94e78b08a8dc5e5e29635105fa6826476cc02bf3b` | 第二份 ARM firmware image；內容不等於 RCDATA `4000` |

`UISettings.ini` 顯示這是 `HFD ISP Tool`，bootloader identity 為 `0C45:8009`／`0C45:8801`、chip `SN32F290`，並含 `CheckDeviceCmd=AA42895AFF7162CC`。這些是 **firmware updater／bootloader** 設定，不是 user-mode `05AC:024F` TFT protocol。

檔名、內嵌 `F98Pro` 字串、240×135 layout 與兩份不相同 firmware blob 共同形成明確的 model/version mismatch 警告。因此：

- 已確認它們是同供應鏈、同 `04 xx` driver family 的 firmware-side 樣本。
- **沒有證據顯示任一 blob 是 OMO100 firmware。**
- 不得執行 updater、不得把 blob 寫入 OMO100，也不得把 bootloader ISP opcode 當 TFT 候選。

## 21. Firmware-side `04 72` 與 ACK 交叉驗證

### 已確認事實

兩份 ARM firmware 都有同型 HID command parser：

1. 從 report buffer 連續讀取 command byte 0 與 byte 1。
2. 明確比較 command byte 0 是否為 `0x04`。
3. 對 command byte 1 作分派，兩份 image 都明確比較 `0x72`。
4. 從 report byte 8–9 組成 little-endian 16-bit 值，傳入／保存至 transfer state；這與 OMO100 driver 已知 block-count 欄位完全一致。
5. `0x72` handler 設定固定儲存位址、清除 transfer counters／狀態並呼叫多個 reinitialization routine。
6. page 處理路徑在每次扣減 remaining-block count 後建立三 byte 回應 `01 5A 02`。

| firmware | outer `04`／buffer evidence | `72` validation | `72` execution dispatch | `72` handler | 固定位址 | `01 5A 02` construction |
|---|---|---:|---:|---:|---:|---:|
| RCDATA `4000` | `0x00003B2A..0x00003B46` | `0x00003EEA` | `0x00004092` → `0x00004168` | `0x00004250` | `0x00740000` | `0x00003AFA..0x00003B04` |
| `SN32F290.bin` | `0x00003B44..0x00003B74` | `0x00003A68` | `0x00003BF0` → `0x00003CD2` | `0x00003D68` | `0x00180000` | `0x000036B2..0x000036BC` |

兩份 firmware 的固定位置不同，正好說明 storage map 是 model／firmware-specific；這些位址不是可移植的 OMO100 參數。`04 72` packet 本身也沒有傳送上述 absolute address，表示 address 由 firmware variant 內建。

### 有證據的推論

- `04 72` 是 persistent TFT bulk-transfer 初始化；handler 的固定非 RAM 位址、remaining-block state、後續 page ACK 與 driver page loop 互相吻合。
- `01 5A 02` 是 bulk page 被接受／處理後的 transport ACK；目前 OMO100 實機已確認同一值，而 sibling firmware 提供了生成它的 code-side 證據。
- 同一 parser 還接受多個 `04 xx` subcommand，但除已由 Windows UI/call site 分類者外，單靠「firmware 接受」不能推出 TFT 用途，更不能推出安全性。

### 尚待 OMO100 firmware 或 capture 驗證

- OMO100 自身 firmware 中 `04 72` handler 的 internal storage address 與完整 state machine。
- ACK 的所有錯誤碼、timeout／retry 條件，以及 `04 18`、`04 02` 在 OMO100 firmware 內的精確語意。
- 是否存在未被官方 UI 使用的 RAM framebuffer、live-frame、frame select 或 play/pause handler。
- sibling parser 中其他已接受 subcommand 的用途；本次沒有依鄰號猜測，也沒有送往硬體。

## 22. 延伸探索結論與 gate

### 候選命令更新

- **最強候選仍是 `04 72`，但用途是 persistent flash-backed bulk upload init，不是 live display。** 它現在同時具有 OMO100 Windows call site、SK80/M87 Pro driver homolog、兩份 ARM firmware dispatch、block-count parsing 與 `01 5A 02` ACK 路徑證據。
- 沒有找到可升格為 RAM preview、live frame、instant slot select、frame select 或 play/pause 的新命令。
- firmware parser 中的其他 accepted values 只有「可被 sibling firmware 分派」這一層證據；缺少 OMO100 firmware、TFT UI call site 與副作用邊界，因此全部留在禁止主動測試區。

### 最終判定

- **Phase 1A+ Mac-only offline protocol archaeology：GO／本輪延伸完成。** 官方 sibling corpus 與 firmware-side control flow 成功補強既有 persistent-upload 基線。
- **新協定／live-display 方向：NEEDS-CAPTURE。** 尚無證據足以確認新 OMO100 command。
- **Mac 主動未知命令測試：NO-GO。** 沒有安全 whitelist 候選；USB 模式本身不改變此判定。

### 下一個安全方向（不需要 Windows 或 VM）

1. 優先取得 **OMO100 精確型號** 的 firmware/update package 或另一版官方 driver；仍只做 hash、解包、ARM parser diff，不執行 updater。
2. 若使用者未來另行明確允許，可在 Mac 上對**既有、已知、已實機驗證的單次操作**加入 process-level logging／被動 capture。只讀 `list` 已完成；若要 capture persistent upload，必須另開階段並再次確認 flash-write 風險。
3. 在沒有 exact OMO100 firmware 或已知操作 capture 前，不因鍵盤已接 USB 就開始 command probing。

## 23. OMO100 精確型號 firmware 公開來源搜尋

### 23.1 操作邊界與方法

本節是使用者另行同意的 **Mac-only、offline-first 精確型號來源搜尋**，執行日期為 2026-07-17。搜尋範圍包括 OMO100 公開下載頁、經銷商鏡像、原品牌／店鋪線索、精確檔名與 hash、韌體版本、Windows binary 建置路徑，以及可能的 ODM／同平台產品線。

- 沒有執行任何下載到的 `.exe`、updater 或 firmware tool。
- 沒有開啟 OMO100 device handle、送出 HID report、執行 upload 或 firmware update。
- 沒有拆機、讀取 flash 或進入 bootloader。
- 所有網頁快照、下載檔與 PDF 都只放在 `/tmp/omo100-phase-1a-20260717/exact-model-hunt/`。
- 搜尋引擎的無結果不是「網路上絕對不存在」的證明；它只表示本輪可公開索引、可直接取得的來源沒有提供精確 firmware。

### 23.2 已確認的精確型號公開檔案

| 來源 | 公開項目 | 大小 | SHA-256 | 結果 |
|---|---|---:|---|---|
| [ktechs File Repository](https://ktechs.store/pages/file-repository) | `OMO100 - Software`，連至 Google Drive 單檔 | 30,142,532 | `9768b317b060dc27950bacb64aeaadfacc05ad288d9ecee1cdb67fca1645a9cf` | 與使用者原有 installer byte-identical |
| [Click & Brew Support & Downloads](https://www.clicknbrewcafe.com/pages/support-downloads)／[公開 Drive folder](https://drive.google.com/drive/folders/1DmlRFu5sYcpIQV3sgI6qugWYS2cOVI2h?usp=drive_link) | `OMO100 Driver-1.0.0.2(1).exe` | 30,142,532 | `9768b317b060dc27950bacb64aeaadfacc05ad288d9ecee1cdb67fca1645a9cf` | 與使用者原有 installer、ktechs mirror 三者 byte-identical |
| 同一 Click & Brew Drive folder | `Guide on How to Use OMO100 Software.pdf` | 601,771 | `2ab9c7e527e0d73afd2ab2248b5a3b8574ea20d9fcd4682092a3bb3d84f20e08` | 兩頁，只涵蓋開啟軟體、Monitor、Import GIF、Upload to keyboard；沒有 firmware／upgrade 流程 |

因此，本輪看似找到兩個獨立 OMO100 軟體來源，實際檔案 corpus 只增加一份說明 PDF；driver binary 沒有增加新版本或新內容。

[什麼值得買的 OMO100 評測](https://post.m.smzdm.com/zz/p/avp63qon/)把產品標為 DM 鍵帽社出品並提到 driver 連結，但沒有暴露另一份可直接驗證的 firmware 或 updater。精確檔名、installer SHA-256、`DeviceDriver.exe` SHA-256、`FirmwareUpdateTool.zip + OMO100`、`OMO100 + firmware V1.20／固件 1.20`、`OMO100 + HFD80CP100／SN32F299／PY25Q128`、PDB 專案字串與 GitHub／百度網盤限制搜尋，本輪均沒有找到精確 firmware image 或不同版官方 driver。

### 23.3 精確 installer 內部狀態

已確認：

- `config.xml` 指定產品 `OMO100`、USB `05AC:024F`、product string `OMO100 keyboard`、軟體 `OMO100 Driver` Beta `1.0.0.2`、網站 `https://dmkeycap.taobao.com`，copyright 為 Dry Martini。
- `layouts/rgb-keyboard.xml` 的 `<firmware version="120" file="" url="" />` 提供期望版本數值 `120`，但 file 與 URL 都是空值。這不能單獨證明實機目前版本，也不能產生 firmware download location。
- 同一 layout 指定 `96×160`、最大 192 frames，與已確認 OMO100 TFT 基線一致。
- extracted app 內沒有可辨識的 `.bin`、`.hex`、`.fw`、`.rom` 或其他 firmware image。
- `DeviceDriver.exe` SHA-256 為 `6daed218dda5bedd5b25b6f46ccba4b6592af488407b367faed18c48571f2939`；PE timestamp 為 2024-07-30 18:51:51 UTC+8。
- binary 內含 `FirmwareUpdateTool.zip`、`%s\temp\FirmwareUpdateTool.zip`、`%s\temp\FirmwareUpdateTool.exe` 字串與 updater download／extract／execute 程式路徑，但 installer 沒有附上該 zip，現有 upgrade URL 也是空值。
- binary 沒有找到 `HFD80CP100`、`SN32F` 或 `PY25Q` 等晶片型號字串。因此不能從精確 OMO100 driver 確認鍵盤內部 MCU／flash 型號。

### 23.4 品牌與供應鏈交叉證據

已確認事實：

- PDB metadata 保留建置路徑：`E:\项目\烽奇\OMO100 Driver代码+打包-20240103不带电量百分比\...\DeviceDriver.pdb`。這直接證明該 Windows binary 的開發／打包環境使用「烽奇」與 OMO100 專案名稱。
- [FCC model-difference declaration](https://fcc.report/FCC-ID/2BH72GMK87/7684905.pdf) 的申請人是 Changsha Kainike Electronic Commerce Co., LTD，列出的 model family 包含 GMK87、GMK104、GMK98、LT75、LT84、LT95、LT104、K86、AK820、AK820MAX、GMK81、OMO100、OMO75、GMK67-S、ABM081，並在法規文件中聲明它們與 GMK87 使用相同 circuit design、PCB layout、shielding 與 interface，差異為型號與外觀顏色。
- [CN221884269U 專利](https://patentimages.storage.googleapis.com/9d/f1/f8/1845fa431e9b4c/CN221884269U.pdf) 的權利人為東莞烽奇科技有限公司，內容是含可拆裝顯示模組的模組化鍵盤；名稱與 PDB 的「烽奇」相符。

有證據的推論：

- Dry Martini／DM 鍵帽社較像 OMO100 的銷售品牌；「烽奇」很可能參與 OMO100 driver 或整機方案開發。PDB 是直接 provenance 證據，但專利本身沒有寫 OMO100，故不能把該專利產品直接等同此鍵盤。
- FCC 文件可用來擴充 sibling corpus 與尋找同供應鏈 updater，但它是 regulatory model-family 聲明；鍵位、螢幕尺寸、storage map 與 firmware variant 仍可能不同。它不構成 firmware 可互刷證據。
- 其他產品的 `HFD80CP100`／`SN32F299`／`PY25Q128` 拆解可解釋 sibling 平台可能的硬體架構，但精確 OMO100 binary 沒有交叉命中，故本報告不把那些晶片列為 OMO100 已確認硬體。

尚待來源或實體證據：

- OMO100（非 OMO100 V2）的精確 firmware image、updater package 與 release notes。
- `<firmware version="120">` 對應的人類版本號是否為 `1.20`，以及它是否與目前實機版本相同。
- `FirmwareUpdateTool.zip` 原本的實際 download URL、簽章、bootloader identity 與內含 firmware。
- OMO100 PCB、MCU、外部 flash 型號與精確 storage map；本輪沒有拆機或讀 flash。

## 24. 精確 firmware 搜尋結論與 gate

- **公開精確型號 firmware：NEEDS-SOURCE。** 本輪沒有找到可驗證的 OMO100 firmware image 或 updater package；兩個公開 driver mirror 都只是既有 installer 的 byte-identical 副本。
- **離線分析 exact firmware：GO，只要先取得檔案。** 若使用者從賣家、品牌方、舊備份或其他擁有者取得 OMO100（非 V2）的 `FirmwareUpdateTool.zip`、updater 或 raw image，可在 Mac 上只做 hash、解包、格式辨識與 parser diff，不需 Windows／VM，也不需鍵盤連線。
- **把 sibling firmware 寫入 OMO100：NO-GO。** FCC model family、ODM 名稱或相似 MCU 都不足以證明 firmware 可互換。
- **新 TFT command／live-display：NEEDS-CAPTURE。** 精確 firmware 仍缺席，故現有 Phase 1A 結論不變。
- **Mac 主動未知命令測試：NO-GO。** 此輪沒有產生可安全加入 whitelist 的新命令。

最實際的下一個來源動作，是由使用者向原賣家／DM 鍵帽社索取「OMO100、非 OMO100 V2、firmware version 120／可能標成 V1.20 的韌體升級工具或原始 firmware」。只需要取得檔案，不需對方遠端操作，也不需 Windows。等待檔案期間，OMO100 不必保持 USB 連線。
