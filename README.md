# OMO100 macOS TFT tool

這是一個根據 `OMO100 Driver Beta 1.0.0.2` 靜態逆向而成的原生 macOS 命令列工具。它不需要執行 Windows `.exe`，也不需要核心驅動；此專案與裝置廠商沒有隸屬關係。

即時打字／Codex／Claude 桌寵顯示的研究與實作階段，請見 [`docs/realtime-pet-implementation-plan.md`](docs/realtime-pet-implementation-plan.md)。

目前狀態：

- `list`：已可用，純讀取 USB/HID 描述。
- `prepare`：將 PNG/JPEG/GIF 轉為鍵盤格式。
- `upload`：已依 Windows 程式協定實作，並以本機測試動畫在 OMO100 USB 有線模式完成逐頁 ACK 與結尾 apply 驗證；協定仍來自逆向，請保留 Beta 心態使用。
- `time`：已依官方 Windows 程式的 `Time Syns` 路徑實作，可寫入小螢幕的日期、時間與星期。

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

需要 macOS 與 Xcode Command Line Tools（`swiftc`）。先自行編譯：

```sh
chmod +x build.sh
./build.sh
```

編譯後可在專案根目錄使用工具：

```sh
./omo100-tool --version
./omo100-tool help
```

請準備自己有權使用的 PNG、JPEG 或 GIF 測試圖片。圖片不會隨專案發佈；這能避免將個人或第三方素材一起公開。

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

用自己的 GIF 測試：

```sh
./omo100-tool upload /path/to/picture.gif --slot 1 --yes-really-upload
```

`upload` 會覆寫鍵盤目前的 TFT 圖片槽。請保持 USB 有線連接，過程中不要拔線或切換連線模式。

## 小螢幕日期與時間

鍵盤的官方 Windows 工具有 `Time Syns` 功能；逆向顯示它會對所選螢幕槽位送出本機日期、時間與星期。macOS 工具提供相同設定：

```sh
# 將 Mac 目前的本機日期時間同步到小螢幕
./omo100-tool time

# 指定一個本機時區的日期與時間
./omo100-tool time 2026-07-21 14:30:00

# 只檢查即將送出的 64-byte 時間資料，不接觸鍵盤
./omo100-tool time 2026-07-21 14:30:00 --dry-run
```

日期與時間依 Mac 的目前本機時區解讀。這個設定會改寫鍵盤的時間 metadata，但不會上傳或覆寫 TFT 圖片。若 macOS 顯示 `0xE00002E2`，請在「系統設定 → 隱私權與安全性 → 輸入監控」允許啟動工具的終端機或 Codex。

## 圖片名稱設定

可將常用圖片綁定到自訂名稱：

```sh
./omo100-tool config set my-animation /absolute/path/to/animation.gif
./omo100-tool config list
./omo100-tool set my-animation
```

在互動式終端機直接執行 `./omo100-tool set`，會列出所有已設定圖片供編號選擇：

```sh
./omo100-tool set
```

設定檔位於 `~/.config/omo/config.json`，在 Git repository 之外，永遠不應提交。`.gitignore` 也會排除意外複製進專案的 `.omo100/`、`omo100.local.json`、`config.local.json` 與 `.env*` 設定。`config set` 會拒絕不存在的圖片；若圖片之後被移動或刪除，`config list` 會標示 `[路徑失效]`，`set` 也會在接觸鍵盤前停止並提示更新路徑。

移除設定名稱：

```sh
./omo100-tool config remove my-animation
```

`set` 仍是完整持久上傳，不適合高頻率狀態切換。

## Windows 原程式的上傳順序

1. 控制 feature report：`04 18`
2. 控制 feature report：`04 72 <slot> 00 00 00 00 00 <block-count-low> <block-count-high>`；區塊數位於 byte 8–9
3. 逐一傳送 4096-byte RGB565 資料區塊，每區塊必須收到 `01 5A 02 ...` input ACK
4. 控制 feature report：`04 02`

macOS 的 IOHID API 會把 report ID 分開傳入，所以原 Windows buffer 最前面的 `00` report ID 不包含在上述 64/4096 bytes 內。

## 安全提醒

這些命令是螢幕圖片傳輸命令，不是韌體更新命令；工具沒有實作任何 firmware update 路徑。不過協定來自逆向，第一次實機上傳仍應視為測試版操作。

## 授權

本專案採用 [MIT License](LICENSE)。它只授權本 repository 內的程式與文件；請勿把未獲授權的裝置廠商檔案、個人設定或第三方素材提交到專案中。
