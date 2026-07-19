# OMO100 macOS TFT tool

這是一個根據 `OMO100 Driver Beta 1.0.0.2` 靜態逆向而成的原生 macOS 命令列工具。它不需要執行 Windows `.exe`，也不需要核心驅動。

即時打字／Codex／Claude 桌寵顯示的研究與實作階段，請見 [`docs/realtime-pet-implementation-plan.md`](docs/realtime-pet-implementation-plan.md)。

目前狀態：

- `list`：已可用，純讀取 USB/HID 描述。
- `prepare`：將 PNG/JPEG/GIF 轉為鍵盤格式。
- `upload`：已依 Windows 程式協定實作，並以 Xavier 動畫在 OMO100 USB 有線模式完成逐頁 ACK 與結尾 apply 驗證；協定仍來自逆向，請保留 Beta 心態使用。

## 已還原的裝置規格

- USB VID/PID：`05AC:024F`（裝置字串 `SONiX / OMO100 keyboard`）
- 控制通道：usage page `0xFF13`、usage `0x01`、64-byte feature report
- 螢幕通道：usage page `0xFF68`、usage `0x61`、4096-byte output report、64-byte input ACK
- 畫面：96 × 160，RGB565 little-endian
- 顯示方向：工具會針對 OMO100 的掃描方向自動垂直翻轉，保留原圖正確的左右方向
- GIF：最多 192 幀
- 資料前置區：256 bytes；第 0 byte 是影格數，第 1...192 bytes 是每幀延遲（每單位 20 ms）
- 播放速度相容：實機會近似固定頻率切換長延遲 GIF；工具會把每幀展開成約 100 ms 的重複硬體影格，避免快速閃爍
- 傳輸：4096-byte 分段

## 使用

工具已附帶編譯好的 `omo100-tool`。若要自行重編：

```sh
chmod +x build.sh
./build.sh
```

專案內也附有從 Codex 寵物 Xavier 原始 spritesheet 擷取的測試動畫。建議先用眨眼較自然的安靜版：

```sh
assets/xavier-calm-blink-96x160.gif
```

它的三個來源影格時長分別為 1.4 秒、0.12 秒、0.6 秒；轉換後會展開為 21 個硬體影格。另保留原本的 6 幀 `assets/xavier-idle-96x160.gif`。

只偵測鍵盤（安全、唯讀）：

```sh
./omo100-tool list
```

只轉換圖片、不碰鍵盤：

```sh
./omo100-tool prepare /path/to/picture.gif --output /tmp/picture.omo100.bin
```

上傳至鍵盤：

```sh
./omo100-tool upload /path/to/picture.gif --slot 1 --yes-really-upload
```

用 Xavier 測試：

```sh
./omo100-tool upload assets/xavier-calm-blink-96x160.gif --slot 1 --yes-really-upload
```

`upload` 會覆寫鍵盤目前的 TFT 圖片槽。請保持 USB 有線連接，過程中不要拔線或切換連線模式。

## Windows 原程式的上傳順序

1. 控制 feature report：`04 18`
2. 控制 feature report：`04 72 <slot> 00 00 00 00 00 <block-count-low> <block-count-high>`；區塊數位於 byte 8–9
3. 逐一傳送 4096-byte RGB565 資料區塊，每區塊必須收到 `01 5A 02 ...` input ACK
4. 控制 feature report：`04 02`

macOS 的 IOHID API 會把 report ID 分開傳入，所以原 Windows buffer 最前面的 `00` report ID 不包含在上述 64/4096 bytes 內。

## 安全提醒

這些命令是螢幕圖片傳輸命令，不是韌體更新命令；工具沒有實作任何 firmware update 路徑。不過協定來自逆向，第一次實機上傳仍應視為測試版操作。
