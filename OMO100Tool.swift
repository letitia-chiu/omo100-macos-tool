import Foundation
import CoreGraphics
import ImageIO
import IOKit.hid
import Darwin

private let toolVersion = "0.3.0"
private let vendorID = 0x05AC
private let productID = 0x024F
private let controlUsagePage = 0xFF13
private let controlUsage = 0x01
private let screenUsagePage = 0xFF68
private let screenUsage = 0x61

private let screenWidth = 96
private let screenHeight = 160
private let frameByteCount = screenWidth * screenHeight * 2
private let headerByteCount = 256
private let transferBlockSize = 4096
private let maximumFrameCount = 192
private let timingCompatibilitySliceSeconds = 0.10
private let commandDelayMicroseconds: useconds_t = 35_000

enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case image(String)
    case device(String)
    case io(String)

    var description: String {
        switch self {
        case .usage(let message), .image(let message), .device(let message), .io(let message):
            return message
        }
    }
}

struct PreparedAnimation {
    let payload: Data
    let sourceFrameCount: Int
    let frameCount: Int
    let blockCount: Int
    let delayUnits: [UInt8]
}

struct ImageConfiguration: Codable {
    var images: [String: String] = [:]
}

final class InputAckState {
    var received = false
    var result: IOReturn = kIOReturnSuccess
    var bytes: [UInt8] = []
}

private let inputReportCallback: IOHIDReportCallback = {
    context, result, _, _, _, report, reportLength in

    guard let context else { return }
    let state = Unmanaged<InputAckState>.fromOpaque(context).takeUnretainedValue()
    state.result = result
    if reportLength > 0 {
        state.bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    } else {
        state.bytes = []
    }
    state.received = true
}

private func numberProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return (value as? NSNumber)?.intValue
}

private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return value as? String
}

private func hex(_ value: Int?, width: Int = 4) -> String {
    guard let value else { return "?" }
    return String(format: "0x%0*X", width, value)
}

private func ioReturnDescription(_ result: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: result))
}

private func matchingDevices() throws -> [IOHIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    // Match only the two vendor-defined interfaces used for TFT transfer.
    // Opening every collection with this VID/PID would collide with tools such
    // as Karabiner that may exclusively own the normal keyboard collection.
    let matchings: [[String: Any]] = [
        [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDPrimaryUsagePageKey as String: controlUsagePage,
            kIOHIDPrimaryUsageKey as String: controlUsage,
        ],
        [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDPrimaryUsagePageKey as String: screenUsagePage,
            kIOHIDPrimaryUsageKey as String: screenUsage,
        ],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)

    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
        throw ToolError.device("無法開啟 IOHIDManager：\(ioReturnDescription(openResult))")
    }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
        return []
    }
    return Array(deviceSet)
}

private func describeDevices(_ devices: [IOHIDDevice]) {
    if devices.isEmpty {
        print("找不到 OMO100（VID 05AC / PID 024F）。請切到 USB 有線模式並重新插拔。"); return
    }

    print("找到 \(devices.count) 個 OMO100 HID collection：")
    for (index, device) in devices.enumerated() {
        let product = stringProperty(device, kIOHIDProductKey as String) ?? "(unknown)"
        let manufacturer = stringProperty(device, kIOHIDManufacturerKey as String) ?? "(unknown)"
        let page = numberProperty(device, kIOHIDPrimaryUsagePageKey as String)
        let usage = numberProperty(device, kIOHIDPrimaryUsageKey as String)
        let input = numberProperty(device, kIOHIDMaxInputReportSizeKey as String)
        let output = numberProperty(device, kIOHIDMaxOutputReportSizeKey as String)
        let feature = numberProperty(device, kIOHIDMaxFeatureReportSizeKey as String)
        let role: String
        if page == controlUsagePage && usage == controlUsage {
            role = "控制通道"
        } else if page == screenUsagePage && usage == screenUsage {
            role = "螢幕資料通道"
        } else {
            role = "其他"
        }
        print("[\(index + 1)] \(role) — \(manufacturer) / \(product)")
        print("    usagePage=\(hex(page)) usage=\(hex(usage, width: 2)) input=\(input ?? 0) output=\(output ?? 0) feature=\(feature ?? 0)")
    }
}

private func gifDelaySeconds(_ source: CGImageSource, index: Int) -> Double {
    guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    else { return 0.10 }

    if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber {
        return unclamped.doubleValue
    }
    if let clamped = gif[kCGImagePropertyGIFDelayTime] as? NSNumber {
        return clamped.doubleValue
    }
    return 0.10
}

private func deviceDelayUnit(seconds: Double) -> UInt8 {
    // The Windows program reads GIF delay in centiseconds, divides it by two,
    // and stores at least 1. One device unit is therefore 20 ms.
    let centiseconds = max(0, Int(floor(seconds * 100.0 + 0.000_001)))
    return UInt8(clamping: max(1, min(255, centiseconds / 2)))
}

private func rgb565Frame(from image: CGImage) throws -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: screenWidth * screenHeight * 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    let sourceWidth = image.width
    let sourceHeight = image.height
    guard sourceWidth > 0, sourceHeight > 0 else {
        throw ToolError.image("圖片尺寸無效")
    }

    let scale = min(
        1.0,
        min(Double(screenWidth) / Double(sourceWidth), Double(screenHeight) / Double(sourceHeight))
    )
    let drawWidth = max(1, Int(Double(sourceWidth) * scale))
    let drawHeight = max(1, Int(Double(sourceHeight) * scale))
    let drawX = (screenWidth - drawWidth) / 2
    let drawY = (screenHeight - drawHeight) / 2

    let contextCreated = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let context = CGContext(
            data: rawBuffer.baseAddress,
            width: screenWidth,
            height: screenHeight,
            bitsPerComponent: 8,
            bytesPerRow: screenWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return false }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
        context.interpolationQuality = .high

        // Produce a top-to-bottom pixel buffer, matching the Windows top-down DIB.
        context.translateBy(x: 0, y: CGFloat(screenHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)
        )
        return true
    }
    guard contextCreated else { throw ToolError.image("無法建立影像轉換 context") }

    var output = [UInt8](repeating: 0, count: frameByteCount)
    // The panel's vertical scan direction is opposite to the rendered buffer.
    // Flip only the vertical axis; flipping both axes mirrors left and right.
    for pixel in 0..<(screenWidth * screenHeight) {
        let x = pixel % screenWidth
        let y = pixel / screenWidth
        let sourcePixel = (screenHeight - 1 - y) * screenWidth + x
        let source = sourcePixel * 4
        let red = UInt16(rgba[source])
        let green = UInt16(rgba[source + 1])
        let blue = UInt16(rgba[source + 2])
        let rgb565 = ((red & 0xF8) << 8) | ((green & 0xFC) << 3) | (blue >> 3)
        output[pixel * 2] = UInt8(truncatingIfNeeded: rgb565)
        output[pixel * 2 + 1] = UInt8(truncatingIfNeeded: rgb565 >> 8)
    }
    return output
}

private func prepareAnimation(at url: URL) throws -> PreparedAnimation {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw ToolError.image("無法讀取圖片：\(url.path)")
    }
    let sourceFrameCount = CGImageSourceGetCount(source)
    guard sourceFrameCount > 0 else { throw ToolError.image("圖片沒有可用影格") }

    let sourceFramesToRead = min(sourceFrameCount, maximumFrameCount)
    var encodedFrames = [([UInt8], UInt8)]()

    // This OMO100 firmware visibly advances long-delay GIFs near a fixed
    // cadence. Repeat frames in 100 ms slices so timing remains stable whether
    // the device honors, caps, or ignores the delay byte.
    for index in 0..<sourceFramesToRead {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw ToolError.image("無法解碼第 \(index + 1) 幀")
        }
        let seconds = gifDelaySeconds(source, index: index)
        let repeatCount = max(1, Int((seconds / timingCompatibilitySliceSeconds).rounded()))
        let delay = deviceDelayUnit(seconds: seconds / Double(repeatCount))
        let frame = try rgb565Frame(from: image)
        for _ in 0..<repeatCount {
            encodedFrames.append((frame, delay))
        }
        guard encodedFrames.count <= maximumFrameCount else {
            throw ToolError.image("為了相容鍵盤播放速度，展開後超過 \(maximumFrameCount) 幀")
        }
    }

    let frameCount = encodedFrames.count
    let unpaddedSize = headerByteCount + frameCount * frameByteCount
    let blockCount = (unpaddedSize + transferBlockSize - 1) / transferBlockSize
    var payload = Data(repeating: 0xFF, count: blockCount * transferBlockSize)
    var delays = [UInt8]()
    delays.reserveCapacity(frameCount)

    payload[0] = UInt8(frameCount)
    for (index, encodedFrame) in encodedFrames.enumerated() {
        let (frame, delay) = encodedFrame
        delays.append(delay)
        payload[1 + index] = delay

        let offset = headerByteCount + index * frameByteCount
        payload.replaceSubrange(offset..<(offset + frameByteCount), with: frame)
    }

    return PreparedAnimation(
        payload: payload,
        sourceFrameCount: sourceFrameCount,
        frameCount: frameCount,
        blockCount: blockCount,
        delayUnits: delays
    )
}

private func chooseChannels(from devices: [IOHIDDevice]) throws -> (control: IOHIDDevice, screen: IOHIDDevice) {
    let control = devices.first {
        numberProperty($0, kIOHIDPrimaryUsagePageKey as String) == controlUsagePage &&
        numberProperty($0, kIOHIDPrimaryUsageKey as String) == controlUsage &&
        (numberProperty($0, kIOHIDMaxFeatureReportSizeKey as String) ?? 0) >= 64
    }
    let screen = devices.first {
        numberProperty($0, kIOHIDPrimaryUsagePageKey as String) == screenUsagePage &&
        numberProperty($0, kIOHIDPrimaryUsageKey as String) == screenUsage &&
        (numberProperty($0, kIOHIDMaxOutputReportSizeKey as String) ?? 0) >= transferBlockSize
    }
    guard let control else { throw ToolError.device("找不到 OMO100 的 64-byte 控制通道（0xFF13/0x01）") }
    guard let screen else { throw ToolError.device("找不到 OMO100 的 4096-byte 螢幕通道（0xFF68/0x61）") }
    return (control, screen)
}

private func sendFeature(_ bytes: [UInt8], to device: IOHIDDevice) throws {
    var packet = [UInt8](repeating: 0, count: 64)
    packet.replaceSubrange(0..<min(bytes.count, packet.count), with: bytes.prefix(packet.count))

    usleep(commandDelayMicroseconds)
    let setResult = packet.withUnsafeBytes { rawBuffer in
        IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            0,
            rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
            packet.count
        )
    }
    guard setResult == kIOReturnSuccess else {
        throw ToolError.io("Feature report \(bytes.prefix(5).map { String(format: "%02X", $0) }.joined(separator: " ")) 寫入失敗：\(ioReturnDescription(setResult))")
    }

    usleep(commandDelayMicroseconds)
    var response = [UInt8](repeating: 0, count: 64)
    var responseLength = response.count
    let getResult = response.withUnsafeMutableBytes { rawBuffer in
        IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            0,
            rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
            &responseLength
        )
    }
    guard getResult == kIOReturnSuccess else {
        throw ToolError.io("控制通道 ACK 讀取失敗：\(ioReturnDescription(getResult))")
    }
    guard responseLength >= 4, response[3] == 1 else {
        let dump = response.prefix(min(responseLength, 12)).map { String(format: "%02X", $0) }.joined(separator: " ")
        throw ToolError.io("控制通道拒絕命令；ACK=\(dump)")
    }
}

private func waitForInputAck(_ state: InputAckState, timeout: TimeInterval) -> Bool {
    let deadline = CFAbsoluteTimeGetCurrent() + timeout
    while !state.received && CFAbsoluteTimeGetCurrent() < deadline {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, true)
    }
    return state.received && state.result == kIOReturnSuccess
}

final class UploadProgress {
    private let total: Int
    private let barWidth = 24
    private let interactive = isatty(STDOUT_FILENO) != 0
    private var lineIsOpen = false

    init(total: Int) {
        self.total = max(1, total)
    }

    func update(current: Int) {
        let boundedCurrent = min(max(0, current), total)
        let fraction = Double(boundedCurrent) / Double(total)
        let percent = Int(fraction * 100.0)
        let filled = boundedCurrent == total
            ? barWidth
            : min(barWidth, max(1, Int(fraction * Double(barWidth))))
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: barWidth - filled)
        let line = "上傳中 [\(bar)] \(String(format: "%3d", percent))% (\(boundedCurrent)/\(total))"

        if interactive {
            fputs("\r\(line)", stdout)
            lineIsOpen = true
            if boundedCurrent == total {
                fputs("\n", stdout)
                lineIsOpen = false
            }
            fflush(stdout)
        } else if boundedCurrent == total {
            print(line)
        }
    }

    func finish() {
        guard interactive, lineIsOpen else { return }
        fputs("\n", stdout)
        fflush(stdout)
        lineIsOpen = false
    }
}

private func upload(_ animation: PreparedAnimation, slot: Int, devices: [IOHIDDevice]) throws {
    guard (1...255).contains(slot) else { throw ToolError.usage("slot 必須介於 1...255") }
    guard animation.blockCount <= 0xFFFF else { throw ToolError.image("轉換後資料太大") }

    let channels = try chooseChannels(from: devices)
    let controlOpen = IOHIDDeviceOpen(channels.control, IOOptionBits(kIOHIDOptionsTypeNone))
    guard controlOpen == kIOReturnSuccess else {
        throw ToolError.device("無法開啟控制通道：\(ioReturnDescription(controlOpen))")
    }
    defer { IOHIDDeviceClose(channels.control, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let screenOpen = IOHIDDeviceOpen(channels.screen, IOOptionBits(kIOHIDOptionsTypeNone))
    guard screenOpen == kIOReturnSuccess else {
        throw ToolError.device("無法開啟螢幕通道：\(ioReturnDescription(screenOpen))")
    }
    defer { IOHIDDeviceClose(channels.screen, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let ackState = InputAckState()
    let ackContext = Unmanaged.passUnretained(ackState).toOpaque()
    let inputBufferCount = 64
    var inputBuffer = [UInt8](repeating: 0, count: inputBufferCount)

    try inputBuffer.withUnsafeMutableBytes { rawBuffer in
        IOHIDDeviceRegisterInputReportCallback(
            channels.screen,
            rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
            inputBufferCount,
            inputReportCallback,
            ackContext
        )
        IOHIDDeviceScheduleWithRunLoop(channels.screen, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(channels.screen, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }

        try sendFeature([0x04, 0x18], to: channels.control)
        try sendFeature([
            0x04, 0x72, UInt8(slot), 0, 0, 0, 0, 0,
            UInt8(truncatingIfNeeded: animation.blockCount),
            UInt8(truncatingIfNeeded: animation.blockCount >> 8),
        ], to: channels.control)

        let total = animation.blockCount
        let progress = UploadProgress(total: total)
        defer { progress.finish() }
        for block in 0..<total {
            let start = block * transferBlockSize
            let end = start + transferBlockSize
            let chunk = animation.payload[start..<end]
            ackState.received = false
            ackState.bytes = []

            let result = chunk.withUnsafeBytes { rawChunk in
                IOHIDDeviceSetReport(
                    channels.screen,
                    kIOHIDReportTypeOutput,
                    0,
                    rawChunk.bindMemory(to: UInt8.self).baseAddress!,
                    transferBlockSize
                )
            }
            guard result == kIOReturnSuccess else {
                throw ToolError.io("第 \(block + 1)/\(total) 個資料區塊寫入失敗：\(ioReturnDescription(result))")
            }
            guard waitForInputAck(ackState, timeout: 0.30) else {
                throw ToolError.io("第 \(block + 1)/\(total) 個資料區塊沒有收到 ACK")
            }
            guard ackState.bytes.count >= 3,
                  ackState.bytes[0] == 0x01,
                  ackState.bytes[1] == 0x5A,
                  ackState.bytes[2] == 0x02 else {
                let dump = ackState.bytes.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
                throw ToolError.io("第 \(block + 1)/\(total) 個資料區塊收到無效 ACK：\(dump)")
            }

            progress.update(current: block + 1)
        }

        try sendFeature([0x04, 0x02], to: channels.control)
    }
}

private func argument(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private let configurationDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("omo", isDirectory: true)

private let configurationFileURL = configurationDirectoryURL
    .appendingPathComponent("config.json", isDirectory: false)

private func loadImageConfiguration() throws -> ImageConfiguration {
    guard FileManager.default.fileExists(atPath: configurationFileURL.path) else {
        return ImageConfiguration()
    }

    do {
        let data = try Data(contentsOf: configurationFileURL)
        return try JSONDecoder().decode(ImageConfiguration.self, from: data)
    } catch {
        throw ToolError.io("無法讀取設定檔：\(configurationFileURL.path)\n\(error.localizedDescription)")
    }
}

private func saveImageConfiguration(_ configuration: ImageConfiguration) throws {
    do {
        try FileManager.default.createDirectory(
            at: configurationDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configurationFileURL, options: .atomic)
    } catch {
        throw ToolError.io("無法寫入設定檔：\(configurationFileURL.path)\n\(error.localizedDescription)")
    }
}

private func imageURL(from path: String) -> URL {
    let expandedPath = (path as NSString).expandingTildeInPath
    if expandedPath.hasPrefix("/") {
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }
    let workingDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    return URL(fileURLWithPath: expandedPath, relativeTo: workingDirectory).standardizedFileURL
}

private func isExistingFile(at url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
}

private func requireExistingImage(at url: URL, name: String? = nil) throws {
    guard isExistingFile(at: url) else {
        if let name {
            throw ToolError.image(
                "設定「\(name)」指向的圖片不存在：\(url.path)\n" +
                "請使用 omo config set \(name) <有效圖片路徑> 更新設定。"
            )
        }
        throw ToolError.image("圖片不存在：\(url.path)")
    }
}

private func runConfigurationCommand(_ arguments: [String]) throws {
    let action = arguments.first ?? "list"
    var configuration = try loadImageConfiguration()

    switch action {
    case "set":
        guard arguments.count == 3 else {
            throw ToolError.usage("用法：omo config set <名稱> <圖片路徑>")
        }
        let name = arguments[1]
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.usage("圖片名稱不能是空白。")
        }
        let url = imageURL(from: arguments[2])
        try requireExistingImage(at: url)
        configuration.images[name] = url.path
        try saveImageConfiguration(configuration)
        print("已設定：\(name) → \(url.path)")

    case "remove":
        guard arguments.count == 2 else {
            throw ToolError.usage("用法：omo config remove <名稱>")
        }
        let name = arguments[1]
        guard configuration.images.removeValue(forKey: name) != nil else {
            throw ToolError.usage("找不到圖片名稱「\(name)」。")
        }
        try saveImageConfiguration(configuration)
        print("已移除：\(name)")

    case "list":
        guard arguments.isEmpty || arguments.count == 1 else {
            throw ToolError.usage("用法：omo config list")
        }
        if configuration.images.isEmpty {
            print("尚未設定圖片。\n使用 omo config set <名稱> <圖片路徑> 新增。")
            return
        }
        for name in configuration.images.keys.sorted() {
            let path = configuration.images[name] ?? ""
            let valid = isExistingFile(at: imageURL(from: path))
            print("\(name)\t\(valid ? "" : "[路徑失效] ")\(path)")
        }

    case "path":
        guard arguments.count == 1 else {
            throw ToolError.usage("用法：omo config path")
        }
        print(configurationFileURL.path)

    default:
        throw ToolError.usage("用法：omo config <set|remove|list|path>")
    }
}

private func chooseConfiguredImage(
    from configuration: ImageConfiguration
) throws -> String? {
    let names = configuration.images.keys.sorted()
    guard !names.isEmpty else {
        throw ToolError.usage(
            "尚未設定圖片。\n" +
            "請先使用 omo config set <名稱> <圖片路徑>。"
        )
    }
    guard isatty(STDIN_FILENO) != 0 else {
        throw ToolError.usage(
            "非互動模式需要指定圖片名稱。\n" +
            "用法：omo set <名稱> [--slot 1]"
        )
    }

    print("選擇要上傳的圖片：")
    for (index, name) in names.enumerated() {
        let path = configuration.images[name] ?? ""
        let suffix = isExistingFile(at: imageURL(from: path)) ? "" : " [路徑失效]"
        print("  \(index + 1). \(name)\(suffix)")
    }
    print("")

    while true {
        fputs("輸入編號（q 取消）： ", stdout)
        fflush(stdout)
        guard let rawInput = readLine() else {
            print("已取消。")
            return nil
        }
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased() == "q" {
            print("已取消。")
            return nil
        }
        if let number = Int(input), (1...names.count).contains(number) {
            return names[number - 1]
        }
        print("請輸入 1–\(names.count)，或 q 取消。")
    }
}

private let usage = """
OMO100 macOS 螢幕工具（逆向 Beta）

用法：
  omo list
  omo prepare <圖片或 GIF> [--output payload.bin]
  omo upload <圖片或 GIF> [--slot 1] --yes-really-upload
  omo config set <名稱> <圖片路徑>
  omo config list
  omo config remove <名稱>
  omo set [名稱] [--slot 1]
  omo --version

說明：
  list      只讀取 USB/HID 描述，不會改變鍵盤。
  prepare   轉成 96x160、RGB565、4096-byte 分段資料，不接觸鍵盤。
  upload    覆寫指定 TFT 圖片槽；目前 OMO100 設定只有 1 槽。
  config    管理圖片名稱與路徑；設定檔位於 ~/.config/omo/config.json。
  set       上傳 config 中的圖片；省略名稱時可從選單選擇。
"""

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "list"

    switch command {
    case "--version", "version":
        print("OMO100 Tool for MacOS \(toolVersion)")

    case "list":
        describeDevices(try matchingDevices())

    case "prepare":
        guard arguments.count >= 2 else { throw ToolError.usage(usage) }
        let inputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let outputPath = argument(after: "--output", in: arguments)
            ?? inputURL.deletingPathExtension().appendingPathExtension("omo100.bin").path
        let prepared = try prepareAnimation(at: inputURL)
        try prepared.payload.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("已建立：\(outputPath)")
        print("影格：\(prepared.frameCount)/\(prepared.sourceFrameCount)，區塊：\(prepared.blockCount)，大小：\(prepared.payload.count) bytes")
        if prepared.sourceFrameCount > maximumFrameCount {
            print("注意：原檔超過 \(maximumFrameCount) 幀，只保留前 \(maximumFrameCount) 幀。")
        }

    case "config":
        try runConfigurationCommand(Array(arguments.dropFirst()))

    case "set":
        let configuration = try loadImageConfiguration()
        let setArguments = Array(arguments.dropFirst())
        let explicitName = setArguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
        let name: String
        if let explicitName {
            name = explicitName
        } else {
            guard let selectedName = try chooseConfiguredImage(from: configuration) else {
                return
            }
            name = selectedName
        }
        guard let path = configuration.images[name] else {
            throw ToolError.usage(
                "找不到圖片名稱「\(name)」。\n" +
                "請先執行 omo config set \(name) <圖片路徑>。"
            )
        }
        let inputURL = imageURL(from: path)
        try requireExistingImage(at: inputURL, name: name)
        let slot = Int(argument(after: "--slot", in: arguments) ?? "1") ?? 1
        let prepared = try prepareAnimation(at: inputURL)
        print("使用設定：\(name) → \(inputURL.path)")
        print("準備上傳 \(prepared.frameCount) 幀、\(prepared.blockCount) 個區塊到 slot \(slot)。")
        try upload(prepared, slot: slot, devices: try matchingDevices())
        print("完成。鍵盤已接受所有區塊與結束命令。")

    case "upload":
        guard arguments.count >= 2, arguments.contains("--yes-really-upload") else {
            throw ToolError.usage("upload 會覆寫鍵盤螢幕圖片，請加上 --yes-really-upload。\n\n\(usage)")
        }
        let inputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let slot = Int(argument(after: "--slot", in: arguments) ?? "1") ?? 1
        let prepared = try prepareAnimation(at: inputURL)
        print("準備上傳 \(prepared.frameCount) 幀、\(prepared.blockCount) 個區塊到 slot \(slot)。")
        try upload(prepared, slot: slot, devices: try matchingDevices())
        print("完成。鍵盤已接受所有區塊與結束命令。")

    case "help", "--help", "-h":
        print(usage)

    default:
        throw ToolError.usage(usage)
    }
}

do {
    try run()
} catch {
    fputs("錯誤：\(error)\n", stderr)
    exit(1)
}
