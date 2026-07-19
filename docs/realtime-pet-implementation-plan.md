# OMO100 即時桌寵顯示實作計劃

日期：2026-07-17  
狀態：計劃已建立，尚未開始即時顯示實作

## 1. 目標

在保留現有「手動選擇 PNG／JPEG／GIF 並上傳」能力的前提下，研究並實作一個 macOS 常駐橋接程式，使 OMO100 鍵盤螢幕可依下列事件切換動畫：

- 使用者持續打字：播放跳躍或活動動畫。
- 使用者停止打字：回到目前已驗證的 idle 動畫。
- Codex／Claude 開始處理、使用工具、等待批准、完成或失敗：播放對應狀態動畫。

本計劃最重要的前置條件是先找到「不反覆寫入鍵盤非揮發儲存空間」的即時顯示或快速切換命令。在找到並實機證明之前，不實作高頻率狀態切換。

## 2. 已確認的實機基線

### 2.1 裝置與格式

- USB VID/PID：`05AC:024F`
- 裝置字串：`SONiX / OMO100 keyboard`
- 控制通道：usage page `0xFF13`、usage `0x01`、64-byte feature report
- 螢幕通道：usage page `0xFF68`、usage `0x61`
- 螢幕 output report：4096 bytes
- 螢幕 input ACK：64 bytes
- 畫面：96 × 160
- 像素：RGB565 little-endian
- 每幀：30,720 bytes
- 最多：192 個硬體影格
- 正確方向：只翻轉垂直軸，不可水平翻轉或旋轉 180°

### 2.2 已驗證的持久上傳協定

1. 控制命令：`04 18`
2. 控制命令：`04 72 <slot> 00 00 00 00 00 <block-low> <block-high>`
3. 傳送 4096-byte 資料區塊，每頁必須收到 `01 5A 02 ...` ACK
4. 控制命令：`04 02`

區塊數位於 `04 72` 的 byte 8–9。放在錯誤位置時，鍵盤只會顯示 `LOADING      %`，沒有數字。

### 2.3 已驗證的 GIF 相容處理

- Header 共 256 bytes。
- byte 0 是硬體影格數。
- byte 1...192 是影格延遲，每單位 20ms。
- OMO100 實機對長延遲的播放不可靠。
- 現有工具會把來源影格展開成約 100ms 的重複硬體影格。
- 已驗證的本機測試 GIF（3 個來源影格）會展開為 21 個硬體影格。
- 實拍驗證眨眼週期約 2.0～2.1 秒，方向與原 GIF 一致。

### 2.4 現有專案能力

- `list`：唯讀列出 OMO100 HID collection。
- `prepare`：轉換 PNG／JPEG／GIF，不接觸鍵盤。
- `upload`：執行完整持久上傳並逐頁驗證 ACK。
- 本機測試素材不納入公開 repository；請使用自己有權使用的 GIF 建立等價回歸測試。

### 2.5 現有協定不適合即時狀態切換

目前的 `upload` 會進入 loading、傳送完整動畫並套用。它適合使用者明確選圖後偶爾更新，不適合每次開始／停止打字或代理狀態改變時呼叫，原因包括：

- 延遲過高，無法即時反應。
- 可能反覆寫入非揮發儲存空間。
- 可能造成 flash 壽命風險。
- 過程可能顯示 loading。

## 3. 範圍與非目標

### 本計劃包含

- 找出 OMO100 是否有 RAM preview、live frame、frame select、animation select 或 slot select 命令。
- 若命令存在，建立安全、低延遲的 macOS 顯示層。
- 建立打字偵測與 idle/typing 狀態機。
- 建立 Codex／Claude hooks 狀態橋接。
- 建立基本的動畫映射、節流、復原與安全機制。

### 本計劃暫不包含

- 修改或刷寫鍵盤韌體。
- 猜測並暴力掃描未知 vendor command。
- 在尚未證明命令安全前高頻率寫入鍵盤。
- 讀取或保存實際按鍵內容、提示內容或對話內容。
- 第一版就製作完整 SwiftUI GUI。
- 依賴仍屬 experimental 的 Codex app-server 作為第一版必要元件。

## 4. 建議架構

```text
OMO100 鍵盤輸入 ─────┐
macOS 打字事件 ───────┤
Codex lifecycle hooks ├─> Local State Bridge ─> State Resolver ─> Display Driver ─> OMO100 TFT
Claude Code hooks ────┘            │                  │
                                   │                  └─ debounce / priority / TTL
                                   └─ Unix socket 或 localhost HTTP
```

建議拆成下列元件：

1. `ImageEncoder`
   - 圖片縮放、置中、黑底、垂直翻轉、RGB565。
2. `PersistentUploader`
   - 保留目前已驗證的完整上傳協定。
3. `LiveDisplayTransport`
   - 只在找到安全的即時命令後建立。
4. `StateBridge`
   - 接收打字、Codex 與 Claude 事件。
5. `StateResolver`
   - 合併多來源狀態，套用 priority、TTL、debounce。
6. `AnimationStore`
   - 預先解碼所有狀態動畫，切換時不重新解 GIF。

## 5. 分階段實作

### Phase 0：建立可回歸的安全基線

#### 0A. 唯讀基線盤點

- 確認專案目前不是 Git repository；在開始實作前由使用者決定是否初始化本機 Git。
- 記錄現有檔案、編譯命令、CLI 行為與已知實機證據。
- 對現有已驗證 payload 產生 hash 與 header 摘要，作為未來回歸依據。
- 此步驟不修改程式、不碰硬體 write。

#### 0B. 基線測試建設

只在 0A／1A 調查報告完成並確認下一步後執行：

- 將協定常數與 payload 編碼從 CLI 流程拆成可測試的純函式，但不可改變現有輸出。
- 保存一份已知正確 payload fixture，驗證：
  - 96 × 160
  - 垂直翻轉、左右不鏡像
  - 21 個硬體影格
  - header delay bytes
  - 4096-byte padding
- 為 `04 72` block count byte 8–9 建立回歸測試。
- 為 ACK `01 5A 02` 與 final feature ACK 建立解析測試。
- 增加 `--dry-run` 或等價測試入口，確保研究階段可以完全不寫入鍵盤。

#### Gate

- 現有 `list`、`prepare`、`upload` 行為未回歸。
- Fixture byte-for-byte 穩定。
- 沒有任何自動測試會碰實機 HID write。

### Phase 1：找出即時顯示或快速切換命令

這是整個專案的 GO／NO-GO 階段。

#### 1A. 靜態逆向

- 以 Windows `DeviceDriver.exe` 為主，列出所有 TFT 相關的 `04 xx` feature commands 與呼叫位置。
- 從 UI 行為與字串交叉追蹤：
  - preview
  - apply
  - edit
  - next/previous image
  - slot selection
  - frame selection
  - play/pause
- 追蹤所有對 usage page `0xFF68`／usage `0x61` 的寫入。
- 區分：
  - RAM 顯示
  - flash 寫入
  - 韌體更新
- 不可僅因 command number 鄰近就直接送出未知命令。

#### 1B. USB 行為擷取

若可使用 Windows 實機或具 USB passthrough 的 Windows VM：

- 使用 USBPcap/Wireshark 擷取官方程式的純預覽、選圖、套用、切換操作。
- 每次只執行一個 UI 動作，保留前後封包差異。
- 優先尋找：
  - 不進入 loading 的畫面更新
  - 不傳完整 payload 的畫面更新
  - 只需單一 feature report 的 slot/frame select

#### 1C. 安全實機驗證

- 只測試由靜態逆向或 USB capture 證明用途的命令。
- 每個候選命令先建立明確 rollback 路徑。
- 測試前後記錄 HID report、ACK、延遲、是否 loading、斷電後是否保留。
- 禁止掃描全部 `04 00...FF`。
- 禁止觸及 firmware/update call path。

#### GO 條件

符合至少一項：

1. 找到 RAM/live-frame 命令，可在不進入 loading 的情況下於 500ms 內更新畫面。
2. 找到預載多動畫後的 instant select 命令，切換時不重新寫入動畫資料。
3. 找到 frame/animation playback control，可安全切換已存在的動畫區段。

#### NO-GO 條件

- 只有完整 `04 18 -> 04 72 -> blocks -> 04 02` 持久上傳路徑。
- 所有候選切換都會寫 flash 或進入 loading。
- 唯一可行路徑需要修改未知韌體。

若 Phase 1 為 NO-GO，停止 reactive display 實作，保留目前可靠的手動上傳工具。

### Phase 2：建立安全的即時顯示層

僅在 Phase 1 GO 後開始。

#### 工作

- 定義能力介面：

```swift
protocol LiveDisplayTransport {
    func show(frame: RGB565Frame) throws
    func select(animation: AnimationID) throws
    func stop() throws
}
```

- 實作能力探測，不能假定所有 `05AC:024F` firmware 都相同。
- 加入：
  - rate limit
  - coalescing，只保留最新狀態
  - duplicate suppression
  - ACK timeout
  - USB reconnect
  - sleep/wake recovery
  - safe fallback to idle
- `PersistentUploader` 與 `LiveDisplayTransport` 必須分開，避免 reactive code 誤呼叫 flash upload。
- 所有持久寫入仍必須要求明確的 `--yes-really-upload`。

#### Gate

- 連續切換 1,000 次沒有進入 loading。
- 斷電後即時狀態不應被當成新預設圖保存，除非該命令本來就是 slot select。
- 狀態事件到畫面變更：median < 250ms、p95 < 500ms。
- USB 拔插後可以自動回到 idle，而不需要重新寫入動畫。

### Phase 3：動畫與狀態機

#### 初始狀態

```text
idle              預設 idle 動畫
typing            跳躍／活動
agentThinking     思考或左右張望
toolRunning       工作／跑步
waitingApproval   舉手、問號或等待
success           短暫開心，再回 idle
error             短暫暈倒或冒汗，再回 idle
```

#### 狀態規則

- 打字第一次 key-down 立即進入 `typing`。
- 最後一次 key-down 後 500～700ms 回到上一個代理狀態或 `idle`。
- `waitingApproval` 優先於一般 `agentThinking`。
- `error`、`success` 為有 TTL 的瞬時狀態。
- 所有狀態都有 TTL；事件來源消失時不得永久卡住。
- 多個 Codex／Claude session 同時工作時，以 priority + 最近活動時間決定畫面。
- 切換動畫前先預解碼，不可在事件熱路徑中重新讀 GIF。

#### 素材限制

- 所有素材統一輸出為 96 × 160。
- 保留左右方向，不做水平鏡像。
- 即時命令若只接受單幀，動畫由 Mac 端定時播放。
- 即時命令若能選擇裝置內動畫，第一版限制為固定少量狀態。

### Phase 4：macOS 常駐橋接程式

#### 打字偵測

優先順序：

1. 若只需要 OMO100，研究是否能從一般 keyboard HID collection 取得 key-down timestamp，而不與 Karabiner 等工具衝突。
2. 否則使用 `CGEventTap`／Input Monitoring。

隱私要求：

- 只保留事件時間與按鍵計數。
- 不保存 key code、字元、modifier 組合或輸入內容。
- UI／README 清楚解釋 Input Monitoring 用途。

#### Bridge transport

第一版建議使用本機 Unix domain socket；若 hooks 整合便利性優先，可使用只綁定 `127.0.0.1` 的 HTTP endpoint。

狀態事件格式：

```json
{
  "source": "codex",
  "sessionId": "optional-session-id",
  "state": "toolRunning",
  "event": "PreToolUse",
  "priority": 50,
  "ttlMs": 30000,
  "timestamp": "2026-07-17T00:00:00Z"
}
```

安全要求：

- 不接受非 localhost 連線。
- 不把 hook payload 原文寫入 log。
- 不讀 transcript 或 prompt 內容。
- 拒絕未知 state。
- 限制事件頻率與 payload 大小。

### Phase 5：Codex 與 Claude 狀態 adapter

#### Codex

優先使用 lifecycle hooks，而不是解析不穩定的 transcript：

- `UserPromptSubmit` -> `agentThinking`
- `PreToolUse` -> `toolRunning`
- `PostToolUse` -> `agentThinking`
- `PermissionRequest` -> `waitingApproval`
- `SubagentStart` -> `toolRunning`
- `SubagentStop` -> `agentThinking`
- `Stop` -> `success`，然後回 `idle`

Codex command hook 目前是同步執行，因此 adapter 必須非常短：只送出 localhost event，立即結束。不要在 hook 裡直接操作 HID 或轉換圖片。

官方參考：

- <https://learn.chatgpt.com/docs/hooks>
- <https://learn.chatgpt.com/docs/developer-commands?surface=cli#cli-codex-app-server>

`codex app-server` 可作為未來需要更完整事件流時的研究選項，但目前屬 experimental，不是 MVP 必要條件。

#### Claude Code

使用對應 hooks：

- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `PostToolUseFailure`
- `Stop`

Claude Code 支援 command、HTTP 等 hook handler；第一版優先使用 localhost HTTP 或短命令，避免耦合到 transcript。

官方參考：

- <https://code.claude.com/docs/en/hooks-guide>
- <https://code.claude.com/docs/en/hooks>

#### Gate

- hooks 執行不明顯增加代理回應延遲。
- Codex／Claude 未啟動時，bridge 仍可單獨運行 idle/typing。
- bridge 未啟動時，hook 必須快速失敗或靜默返回，不可阻塞代理。
- 不依賴讀取提示或回答內容判斷狀態。

### Phase 6：產品化與選圖介面

MVP 穩定後再考慮：

- macOS menu bar app。
- `NSOpenPanel` 選擇 PNG／JPEG／GIF。
- 狀態到動畫的設定頁。
- start at login。
- USB 連線狀態與錯誤提示。
- 手動 preview。
- 恢復預設 idle 動畫。

GUI 必須清楚區分：

- 「即時預覽／切換」：不寫 flash。
- 「設為鍵盤預設圖片」：執行持久上傳，需二次確認。

## 6. 測試策略

### 不接硬體的自動測試

- RGB565 golden files。
- 方向與鏡像 fixture。
- GIF 100ms 展開。
- 192 幀上限。
- header、padding、block count。
- ACK parser。
- state priority、TTL、debounce。
- event schema validation。
- bridge rate limiting。

### 接硬體的整合測試

- 只讀 capability probe。
- 單幀即時顯示。
- idle <-> typing 重複切換。
- agentThinking -> toolRunning -> waitingApproval -> success。
- 30 分鐘連續打字。
- 1,000 次狀態切換。
- USB 拔插、Mac sleep/wake。
- Codex／Claude 同時發送事件。

### 使用者實機驗收

- 左右方向與來源素材一致。
- idle 眨眼週期自然。
- 持續打字時能快速切到跳躍。
- 停止打字後自然回 idle。
- waiting/working/success 狀態易辨識。
- 即時切換時不顯示 loading。
- 不因 hooks 或 bridge 造成打字延遲。

## 7. 風險與防護

| 風險 | 防護 |
|---|---|
| 未知命令進入 firmware update | 只測有靜態或 USB capture 證據的命令；禁止 command brute force |
| 高頻寫入 flash | reactive path 不得依賴 `PersistentUploader` |
| HID collection 與 Karabiner 衝突 | 只開必要 collection；打字偵測提供 CGEventTap fallback |
| Input Monitoring 隱私 | 不保存 key code 或文字，只保存 timestamp/count |
| 狀態事件過多 | debounce、coalescing、rate limit、duplicate suppression |
| hook 阻塞 Codex／Claude | hook 只發本機事件並立即返回 |
| 多 session 狀態互相覆蓋 | sessionId、priority、TTL、最近活動規則 |
| 實驗性介面變動 | MVP 用 lifecycle hooks；app-server 只列為研究選項 |
| USB 斷線造成卡死 | timeout、reconnect、idle fallback |

## 8. 決策樹

```text
找到 RAM/live-frame？
├─ 是 -> 做完整即時桌寵：Mac 端播放所有動畫
└─ 否
   └─ 找到多動畫預載 + instant select？
      ├─ 是 -> 做有限狀態桌寵：預載固定動畫並快速切換
      └─ 否 -> NO-GO：保留手動上傳，不做 reactive display
```

不以修改鍵盤韌體作為此計劃的 fallback。

## 9. 下一個 session 的第一個交付物

下一個 session 先執行 Phase 0A 與 Phase 1A 的唯讀調查，不執行 Phase 0B，也不急著寫 reactive code。第一份報告至少包含：

1. 現有專案檔案與可回歸基線。
2. Windows driver TFT command inventory。
3. 每個候選命令的 call site、資料方向、payload 長度與推定用途。
4. 明確區分事實、推論、尚待實機驗證。
5. 是否存在值得進入 USB capture／安全實機驗證的候選命令。
6. Phase 1A 的 `GO / NO-GO / NEEDS-CAPTURE` 結論。

第一份報告寫入：`docs/research/phase-1a-static-reverse-report.md`。此報告是該 session 唯一預期的專案內容新增；其餘分析中間產物放在 `/tmp`，不要修改現有程式。

在 Phase 1A 報告完成前：

- 不向鍵盤送未知命令。
- 不執行 firmware update。
- 不修改目前已驗證的 `upload` 協定。
- 不建立會頻繁呼叫 `upload` 的常駐程式。

## 10. 相關資料

- 專案主程式：[`../OMO100Tool.swift`](../OMO100Tool.swift)
- 使用說明：[`../README.md`](../README.md)
- 靜態逆向報告：[`research/phase-1a-static-reverse-report.md`](research/phase-1a-static-reverse-report.md)
- 供應商 installer、解壓後的 Windows app、實機錄影及個人測試素材均為本機研究資料，不放入 repository。請只使用你有權取得與使用的副本，並將中間分析檔放在系統暫存目錄。

## 11. 專案操作規則

- 除非使用者明確要求，不執行 `git push`。
- 對未知 HID command 採 evidence-first，不做暴力測試。
- 保留目前已驗證可用的手動上傳路徑。
- 報告實機結果時，區分自動協定證據與使用者肉眼驗收。
