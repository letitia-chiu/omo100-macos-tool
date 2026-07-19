import Foundation
import CoreGraphics
import ImageIO
import IOKit.hid

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

            if block == 0 || block + 1 == total || (block + 1) % max(1, total / 20) == 0 {
                let percent = Int(Double(block + 1) / Double(total) * 100.0)
                print("上傳中：\(percent)% (\(block + 1)/\(total))")
            }
        }

        try sendFeature([0x04, 0x02], to: channels.control)
    }
}

private func argument(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private let usage = """
OMO100 macOS 螢幕工具（逆向 Beta）

用法：
  omo100-tool list
  omo100-tool prepare <圖片或 GIF> [--output payload.bin]
  omo100-tool upload <圖片或 GIF> [--slot 1] --yes-really-upload

說明：
  list      只讀取 USB/HID 描述，不會改變鍵盤。
  prepare   轉成 96x160、RGB565、4096-byte 分段資料，不接觸鍵盤。
  upload    覆寫指定 TFT 圖片槽；目前 OMO100 設定只有 1 槽。
"""

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "list"

    switch command {
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
