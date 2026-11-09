// WebExportPlugin.swift — Compositor「Web 导出」插件（ABI v2 · export 类）
//
// C ABI v2 插件契约（与主程序 Plugins/CompositorPluginKit.swift 保持一致）：
//   entry 结构在 v1（撕边 48 字节）之上追加 encodeImage 函数指针 @48：
//     struct CompositorPluginEntry {
//       UInt32 abiVersion;                       // @0   = 2
//       const char* identifier;                  // @8
//       const char* name;                        // @16
//       const char* symbolName;                  // @24
//       const char* paramsJSON;                  // @32
//       int (*buildCutOutline)(...);             // @40  v1：撕边类（本插件为 NULL）
//       int (*encodeImage)(...);                 // @48  v2：导出类
//     }
//
//   encodeImage(rgba8 预乘像素, w, h, bytesPerRow, 参数 JSON,
//               outData**, outLength*, 错误缓冲) -> 0 成功 / 1 参数错误 / 2 编码失败
//   outData 由插件 malloc，宿主负责 free()（同一 libSystem 分配器）。
//
// 编码管线（以压缩体积为核心）：
//   WebP  有损：vendored libwebp 1.6.0（quality 1-100 + alpha 保留，method 随档位）
//   WebP  无损：libwebp lossless（quality 作为 effort，官方推荐 75）
//   JPEG      ：ImageIO（quality 0-100，白底填充透明区）
//   PNG 全彩  ：ImageIO 无损 RGBA
//   PNG8 调色板：中位切分量化（2-256 色，可选 Floyd–Steinberg）+ 手写 PNG chunk
//               （PLTE + tRNS 二值透明 + zlib deflate 等级 9）
//   GIF       ：同一量化管线 + 手写 GIF89a（LZW + Graphic Control Extension 透明）
//
// 缩放：<100% 时 CGContext 高质量重采样（体积压缩的第一杠杆）。
// 透明处理：WebP / PNG 全彩保留 alpha；JPEG 白底；PNG8 / GIF 二值透明（阈值 0）。
// 无 Foundation 强制：Data 仅作 CFData 桥接（宿主进程内 Foundation 必然已加载）。

import CoreGraphics
import ImageIO
import Darwin
import Foundation // Data（宿主进程内 Foundation 必然已加载，无额外运行时成本）

// MARK: - C ABI v2（宿主与插件共同遵守的稳定接口）

public typealias CompositorBuildCutOutlineFn = @convention(c) (
    _ rect: UnsafePointer<Float>,
    _ paramsJSON: UnsafePointer<CChar>?,
    _ outPoints: UnsafeMutablePointer<Float>?,
    _ ioCount: UnsafeMutablePointer<Int32>
) -> Int32

/// int encodeImage(const unsigned char* rgba, int w, int h, int bytesPerRow,
///                 const char* paramsJSON, unsigned char** outData, unsigned long* outLength,
///                 char* errBuf, int errBufSize)
public typealias CompositorEncodeImageFn = @convention(c) (
    _ rgba: UnsafePointer<UInt8>,
    _ width: Int32, _ height: Int32, _ bytesPerRow: Int32,
    _ paramsJSON: UnsafePointer<CChar>?,
    _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outLength: UnsafeMutablePointer<UInt>?,
    _ errBuf: UnsafeMutablePointer<CChar>?, _ errBufSize: Int32
) -> Int32

public struct CompositorPluginEntry {
    public var abiVersion: UInt32
    public var identifier: UnsafePointer<CChar>
    public var name: UnsafePointer<CChar>
    public var symbolName: UnsafePointer<CChar>
    public var paramsJSON: UnsafePointer<CChar>
    public var buildCutOutline: CompositorBuildCutOutlineFn?
    public var encodeImage: CompositorEncodeImageFn?
}

// MARK: - 插件元数据与参数 schema

let pluginIdentifier = "web-export"
let pluginName = "Web Export"
let pluginSymbol = "square.and.arrow.down"

// 分组：shared 常显；format 当前值决定显示哪组；pngMode=palette 时才显示 palette 组。
// preset 的 presets 字段：切档位时宿主批量填参（custom 为空 = 保留现状，仅切换自身）。
let pluginParamsJSON = """
{
  "interaction": "export",
  "params": [
    {"key":"format","label":"Format","group":"shared","type":"choice",
     "choices":["webp","jpeg","png","gif"],"choiceLabels":["WebP","JPEG","PNG","GIF"],"default":"webp"},
    {"key":"preset","label":"Preset","group":"shared","type":"choice",
     "choices":["high","standard","extreme","custom"],"choiceLabels":["High quality","Standard","Extreme","Custom"],
     "default":"standard",
     "presets":{
       "high":{"quality":92,"webpLossless":0,"pngMode":"truecolor","colors":256,"dither":1,"scale":100},
       "standard":{"quality":82,"webpLossless":0,"pngMode":"truecolor","colors":128,"dither":1,"scale":100},
       "extreme":{"quality":62,"webpLossless":0,"pngMode":"palette","colors":64,"dither":1,"scale":100},
       "custom":{}
     }},
    {"key":"quality","label":"Quality","group":"lossy","type":"float","min":1,"max":100,"default":82,"suffix":"%"},
    {"key":"webpLossless","label":"Lossless","group":"webp","type":"int","min":0,"max":1,"default":0},
    {"key":"pngMode","label":"PNG Mode","group":"png","type":"choice",
     "choices":["truecolor","palette"],"choiceLabels":["Truecolor (lossless)","Palette (PNG8)"],"default":"truecolor"},
    {"key":"colors","label":"Colors","group":"palette","type":"int","min":2,"max":256,"default":128},
    {"key":"dither","label":"Dither","group":"palette","type":"int","min":0,"max":1,"default":1},
    {"key":"scale","label":"Scale","group":"shared","type":"float","min":5,"max":100,"default":100,"suffix":"%"}
  ]
}
"""

// MARK: - 极简参数解析（扁平 JSON 对象；与撕边插件同实现）

func parseParams(_ json: UnsafePointer<CChar>?) -> [String: Any] {
    guard let json else { return [:] }
    let s = String(cString: json)
    var params: [String: Any] = [:]
    var i = s.startIndex
    func skipWS() { while i < s.endIndex, s[i] == " " || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i = s.index(after: i) } }
    guard i < s.endIndex, s[i] == "{" else { return params }
    i = s.index(after: i)
    while i < s.endIndex {
        skipWS()
        guard i < s.endIndex else { break }
        if s[i] == "}" { break }
        guard s[i] == "\"" else { break }
        i = s.index(after: i)
        var key = ""
        while i < s.endIndex, s[i] != "\"" { key.append(s[i]); i = s.index(after: i) }
        guard i < s.endIndex else { break }
        i = s.index(after: i)
        skipWS()
        guard i < s.endIndex, s[i] == ":" else { break }
        i = s.index(after: i)
        skipWS()
        if i < s.endIndex, s[i] == "\"" {
            i = s.index(after: i)
            var value = ""
            while i < s.endIndex, s[i] != "\"" { value.append(s[i]); i = s.index(after: i) }
            i = i < s.endIndex ? s.index(after: i) : i
            params[key] = value
        } else {
            var num = ""
            while i < s.endIndex, (s[i].isNumber || s[i] == "-" || s[i] == "+" || s[i] == "." || s[i] == "e" || s[i] == "E") {
                num.append(s[i]); i = s.index(after: i)
            }
            if let d = Double(num) { params[key] = d }
        }
        skipWS()
        if i < s.endIndex, s[i] == "," { i = s.index(after: i) }
    }
    return params
}

// MARK: - 像素工具（CG C API）

let sRGBSpace = CGColorSpaceCreateDeviceRGB()

/// 预乘 RGBA 数据 → CGImage（sRGB 8bit RGBA）。CFData 拥有拷贝出的数据。
func makeCGImage(from rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let cf = rgba.withUnsafeBufferPointer({ p in
        CFDataCreate(kCFAllocatorDefault, p.baseAddress, p.count)
    }), let provider = CGDataProvider(data: cf) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: sRGBSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// CGImage → 非预乘 RGBA8 buffer（WebP / 量化输入需要非预乘）。
/// CG 对非预乘位图上下文支持不稳，先画进预乘上下文再手动反预乘。
func unpremultipliedRGBA(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let a = Int(pixels[i + 3])
        guard a > 0, a < 255 else { continue }
        pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / a))
        pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / a))
        pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / a))
    }
    return (pixels, w, h)
}

/// 高质量重采样到新尺寸。
func resample(_ image: CGImage, toWidth w: Int, toHeight h: Int) -> CGImage? {
    guard w != image.width || h != image.height else { return image }
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: sRGBSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

// MARK: - ImageIO 编码（JPEG / PNG 全彩）

func encodeWithImageIO(_ image: CGImage, typeID: String, quality: Double?) -> Data? {
    guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0),
          let destination = CGImageDestinationCreateWithData(data, typeID as CFString, 1, nil) else { return nil }
    var properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: 72.0, kCGImagePropertyDPIHeight: 72.0,
    ]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    // 渲染像素本无 EXIF/GPS 等元数据；显式写入的只有 DPI，天然满足体积最小化。
    return (data as Data) as Data
}

/// JPEG：透明区铺白底再编码。
func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: sRGBSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let flattened = ctx.makeImage() else { return nil }
    return encodeWithImageIO(flattened, typeID: "public.jpeg", quality: quality)
}

// MARK: - 中位切分量化（PNG8 / GIF 共用）

struct RGB { var r: UInt8; var g: UInt8; var b: UInt8 }

final class MedianBox {
    var indices: [Int] = []
    var rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0
    var count: Int { indices.count }
}

struct QuantizeResult {
    let palette: [RGB]               // palette[0] = 全透明位（若 hasTransparency）
    let indices: [UInt8]
    let hasTransparency: Bool
}

private func refreshBox(_ box: MedianBox, samples: [RGB]) {
    box.rMin = 255; box.rMax = 0; box.gMin = 255; box.gMax = 0; box.bMin = 255; box.bMax = 0
    for idx in box.indices {
        let s = samples[idx]
        box.rMin = min(box.rMin, Int(s.r)); box.rMax = max(box.rMax, Int(s.r))
        box.gMin = min(box.gMin, Int(s.g)); box.gMax = max(box.gMax, Int(s.g))
        box.bMin = min(box.bMin, Int(s.b)); box.bMax = max(box.bMax, Int(s.b))
    }
}

private func nearestIndex(_ r: Float, _ g: Float, _ b: Float, _ palette: [RGB], skipZero: Bool) -> Int {
    var best = 0
    var bestDist = Float.greatestFiniteMagnitude
    for (i, c) in palette.enumerated() {
        if skipZero && i == 0 { continue }
        let dr = r - Float(c.r), dg = g - Float(c.g), db = b - Float(c.b)
        let d = dr * dr + dg * dg + db * db
        if d < bestDist { bestDist = d; best = i }
    }
    return best
}

/// 非预乘 RGBA → 量化（palette[0] = 全透明，仅当存在全透明像素）。
/// - dither: Floyd–Steinberg 误差扩散；关闭时最近邻 + RGB565 缓存。
func quantize(_ rgba: [UInt8], width: Int, height: Int, maxColors: Int, dither: Bool) -> QuantizeResult? {
    let w = width, h = height
    let pixels = w * h
    var hasTransparency = false
    for i in 0..<pixels where rgba[i * 4 + 3] == 0 { hasTransparency = true; break }

    // 均匀采样 ≤ 65536 个不透明像素定色板（索引分配仍全图）。
    let strideStep = max(1, pixels / 65536)
    var samples: [RGB] = []
    samples.reserveCapacity(pixels / strideStep + 16)
    var i = 0
    while i < pixels {
        if rgba[i * 4 + 3] > 0 {
            samples.append(RGB(r: rgba[i * 4], g: rgba[i * 4 + 1], b: rgba[i * 4 + 2]))
        }
        i += strideStep
    }
    guard !samples.isEmpty else {
        return QuantizeResult(palette: [RGB(r: 0, g: 0, b: 0)], indices: [UInt8](repeating: 0, count: pixels),
                              hasTransparency: true)
    }

    // 中位切分：每次切「像素数 × 主分量跨度」得分最高的箱。
    var boxes: [MedianBox] = [MedianBox()]
    boxes[0].indices = Array(0..<samples.count)
    refreshBox(boxes[0], samples: samples)
    let paletteColors = max(1, hasTransparency ? maxColors - 1 : maxColors)
    while boxes.count < paletteColors {
        var best = -1
        var bestScore = 0
        for (bi, box) in boxes.enumerated() where box.count > 1 {
            let span = max(box.rMax - box.rMin, box.gMax - box.gMin, box.bMax - box.bMin)
            let score = box.count * max(1, span)
            if score > bestScore { bestScore = score; best = bi }
        }
        guard best >= 0 else { break }
        let box = boxes.remove(at: best)
        let rSpan = box.rMax - box.rMin, gSpan = box.gMax - box.gMin, bSpan = box.bMax - box.bMin
        let sorted: [Int]
        if rSpan >= gSpan && rSpan >= bSpan {
            sorted = box.indices.sorted { samples[$0].r < samples[$1].r }
        } else if gSpan >= bSpan {
            sorted = box.indices.sorted { samples[$0].g < samples[$1].g }
        } else {
            sorted = box.indices.sorted { samples[$0].b < samples[$1].b }
        }
        let mid = sorted.count / 2
        let a = MedianBox(); a.indices = Array(sorted[..<mid])
        let b = MedianBox(); b.indices = Array(sorted[mid...])
        refreshBox(a, samples: samples); refreshBox(b, samples: samples)
        boxes.append(a); boxes.append(b)
    }

    var palette: [RGB] = boxes.map { box -> RGB in
        var r = 0, g = 0, b = 0
        for idx in box.indices {
            r += Int(samples[idx].r); g += Int(samples[idx].g); b += Int(samples[idx].b)
        }
        let n = max(1, box.count)
        return RGB(r: UInt8(min(255, r / n)), g: UInt8(min(255, g / n)), b: UInt8(min(255, b / n)))
    }
    if hasTransparency { palette.insert(RGB(r: 0, g: 0, b: 0), at: 0) }

    // 索引分配。
    var indices = [UInt8](repeating: 0, count: pixels)
    if dither {
        // Floyd–Steinberg：7/16 → 右，3/16 → 下左，5/16 → 下，1/16 → 下右。
        var errorR = [Float](repeating: 0, count: w + 2)
        var errorG = [Float](repeating: 0, count: w + 2)
        var errorB = [Float](repeating: 0, count: w + 2)
        for y in 0..<h {
            var nextR = [Float](repeating: 0, count: w + 2)
            var nextG = [Float](repeating: 0, count: w + 2)
            var nextB = [Float](repeating: 0, count: w + 2)
            for x in 0..<w {
                let p = y * w + x
                if rgba[p * 4 + 3] == 0 { indices[p] = 0; continue } // 透明 → palette[0]
                let fr = min(255, max(0, Float(rgba[p * 4]) + errorR[x + 1]))
                let fg = min(255, max(0, Float(rgba[p * 4 + 1]) + errorG[x + 1]))
                let fb = min(255, max(0, Float(rgba[p * 4 + 2]) + errorB[x + 1]))
                let idx = nearestIndex(fr, fg, fb, palette, skipZero: hasTransparency)
                indices[p] = UInt8(idx)
                let er = fr - Float(palette[idx].r), eg = fg - Float(palette[idx].g), eb = fb - Float(palette[idx].b)
                if x + 1 < w {
                    errorR[x + 2] += er * 7 / 16; errorG[x + 2] += eg * 7 / 16; errorB[x + 2] += eb * 7 / 16
                }
                nextR[x] += er * 3 / 16; nextG[x] += eg * 3 / 16; nextB[x] += eb * 3 / 16
                nextR[x + 1] += er * 5 / 16; nextG[x + 1] += eg * 5 / 16; nextB[x + 1] += eb * 5 / 16
                if x + 2 < w {
                    nextR[x + 2] += er / 16; nextG[x + 2] += eg / 16; nextB[x + 2] += eb / 16
                }
            }
            errorR = nextR; errorG = nextG; errorB = nextB
        }
    } else {
        var cache: [UInt32: UInt8] = [:]
        cache.reserveCapacity(4096)
        for p in 0..<pixels {
            if rgba[p * 4 + 3] == 0 { indices[p] = 0; continue }
            let r = UInt32(rgba[p * 4]), g = UInt32(rgba[p * 4 + 1]), b = UInt32(rgba[p * 4 + 2])
            let key = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            if let hit = cache[key] { indices[p] = hit; continue }
            let idx = nearestIndex(Float(r), Float(g), Float(b), palette, skipZero: hasTransparency)
            cache[key] = UInt8(idx)
            indices[p] = UInt8(idx)
        }
    }
    return QuantizeResult(palette: palette, indices: indices, hasTransparency: hasTransparency)
}

// MARK: - PNG8 写出（手写 chunk + zlib deflate）

func crc32of(_ bytes: [UInt8]) -> UInt32 {
    bytes.withUnsafeBufferPointer { p -> UInt32 in
        guard let base = p.baseAddress else { return 0 }
        let bytef = base.withMemoryRebound(to: Bytef.self, capacity: p.count) { $0 }
        return UInt32(crc32(0, bytef, uInt(p.count)))
    }
}

private func be32bytes(_ v: Int) -> [UInt8] {
    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

private func appendChunk(_ out: inout [UInt8], type: [UInt8], payload: [UInt8]) {
    out += be32bytes(payload.count)
    out += type
    out += payload
    let crc = crc32of(type + payload)
    out += [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
}

private func deflateMax(_ raw: [UInt8]) -> [UInt8]? {
    let bound = compressBound(uLong(raw.count))
    var dest = [UInt8](repeating: 0, count: Int(bound))
    var destLen = bound
    let rc = raw.withUnsafeBufferPointer { sp -> Int32 in
        dest.withUnsafeMutableBufferPointer { dp in
            compress2(dp.baseAddress!, &destLen, sp.baseAddress!, uLong(raw.count), 9)
        }
    }
    guard rc == 0 else { return nil }
    dest.removeLast(dest.count - Int(destLen))
    return dest
}

/// PNG8：colortype 3（索引色）+ PLTE + tRNS（二值透明）+ filter 0 + deflate 等级 9。
func writePNG8(_ result: QuantizeResult, width: Int, height: Int) -> Data? {
    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    // IHDR：宽高 / 位深 8 / colortype 3 / compression 0 / filter 0 / interlace 0
    appendChunk(&out, type: [0x49, 0x48, 0x44, 0x52],
                payload: be32bytes(width) + be32bytes(height) + [8, 3, 0, 0, 0])
    // PLTE
    var plte: [UInt8] = []
    plte.reserveCapacity(result.palette.count * 3)
    for c in result.palette { plte += [c.r, c.g, c.b] }
    appendChunk(&out, type: [0x50, 0x4C, 0x54, 0x45], payload: plte)
    // tRNS：palette[0] 透明
    if result.hasTransparency {
        appendChunk(&out, type: [0x74, 0x52, 0x4E, 0x53],
                    payload: result.palette.enumerated().map { $0.offset == 0 ? UInt8(0) : UInt8(255) })
    }
    // IDAT：每行 filter 0 + 索引行
    var raw: [UInt8] = []
    raw.reserveCapacity(height * (width + 1))
    for y in 0..<height {
        raw.append(0)
        raw.append(contentsOf: result.indices[(y * width)..<((y + 1) * width)])
    }
    guard let idat = deflateMax(raw) else { return nil }
    appendChunk(&out, type: [0x49, 0x44, 0x41, 0x54], payload: idat)
    appendChunk(&out, type: [0x49, 0x45, 0x4E, 0x44], payload: [])
    return out.withUnsafeBufferPointer { p in
        CFDataCreate(kCFAllocatorDefault, p.baseAddress, p.count).map { $0 as Data }
    }
}

// MARK: - GIF89a 写出（LZW）

/// GIF LZW 编码（LSB-first 位打包；字典满 4096 输出 clear 重置）。
private func lzwEncode(_ pixels: [UInt8], minCodeSize: Int) -> [UInt8] {
    let clearCode = 1 << minCodeSize
    let eoiCode = clearCode + 1
    var codeSize = minCodeSize + 1
    var nextCode = eoiCode + 1

    var dict: [UInt64: Int] = [:] // (prefixCode << 8) | byte → code
    dict.reserveCapacity(4096)
    var out: [UInt8] = []
    out.reserveCapacity(pixels.count / 2 + 64)
    var bitBuffer = 0
    var bitCount = 0

    func emit(_ code: Int) {
        bitBuffer |= code << bitCount
        bitCount += codeSize
        while bitCount >= 8 {
            out.append(UInt8(bitBuffer & 0xFF))
            bitBuffer >>= 8
            bitCount -= 8
        }
    }

    emit(clearCode)
    var current = Int(pixels[0])
    for i in 1..<pixels.count {
        let byte = Int(pixels[i])
        let key = UInt64(current) << 8 | UInt64(byte)
        if let code = dict[key] {
            current = code
        } else {
            emit(current)
            if nextCode < 4096 {
                dict[key] = nextCode
                nextCode += 1
                if nextCode == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
            } else {
                emit(clearCode)
                dict.removeAll(keepingCapacity: true)
                codeSize = minCodeSize + 1
                nextCode = eoiCode + 1
            }
            current = byte
        }
    }
    emit(current)
    emit(eoiCode)
    if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
    return out
}

/// GIF89a：全局色表 + （可选）透明 GCE + LZW 压缩的索引图。
func writeGIF(_ result: QuantizeResult, width: Int, height: Int) -> Data? {
    var out: [UInt8] = []
    out += Array("GIF89a".utf8)

    var bits = 1
    while (1 << bits) < result.palette.count { bits += 1 }
    let tableColors = 1 << bits
    let minCodeSize = max(2, min(8, bits))

    // Logical Screen Descriptor：GCT flag + 色分辨 + GCT 大小
    out += [UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF),
            UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)]
    out += [UInt8(0x80 | 0x70 | (minCodeSize - 1)), 0, 0]
    for i in 0..<tableColors {
        if i < result.palette.count { out += [result.palette[i].r, result.palette[i].g, result.palette[i].b] }
        else { out += [0, 0, 0] }
    }
    // Graphic Control Extension：透明 index 0、无延时
    if result.hasTransparency {
        out += [0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00]
    }
    // Image Descriptor
    out += [0x2C, 0, 0, 0, 0,
            UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF),
            UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF), 0]
    // LZW 数据子块
    out += [UInt8(minCodeSize)]
    let lzw = lzwEncode(result.indices, minCodeSize: minCodeSize)
    var i = 0
    while i < lzw.count {
        let n = min(255, lzw.count - i)
        out += [UInt8(n)]
        out += Array(lzw[i..<(i + n)])
        i += n
    }
    out += [0, 0x3B] // 子块结束 + Trailer
    return out.withUnsafeBufferPointer { p in
        CFDataCreate(kCFAllocatorDefault, p.baseAddress, p.count).map { $0 as Data }
    }
}

// MARK: - libwebp 封装（vendored 1.6.0，bridging header 引入）

func encodeWebP(_ image: CGImage, quality: Double, lossless: Bool) -> Data? {
    guard let (rgba, w, h) = unpremultipliedRGBA(image) else { return nil }
    return rgba.withUnsafeBufferPointer { buffer -> Data? in
        var config = WebPConfig()
        // method 随质量：高质省时间，极限压更狠（method 6 = 最慢最小）。
        let method = quality >= 85 ? 4 : (quality >= 65 ? 5 : 6)
        guard shim_WebPConfigInit(&config, lossless ? 1 : 0, Float(quality), Int32(method)) != 0 else { return nil }
        var picture = WebPPicture()
        guard shim_WebPPictureInit(&picture) != 0 else { return nil }
        defer { shim_WebPPictureFree(&picture) }
        picture.width = Int32(w)
        picture.height = Int32(h)
        picture.use_argb = 1
        guard WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(w * 4)) != 0 else { return nil }
        var writer = WebPMemoryWriter()
        shim_WebPMemoryWriterInit(&writer)
        var result: Data?
        withUnsafeMutablePointer(to: &writer) { writerPtr in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPtr)
            if WebPEncode(&config, &picture) != 0, writerPtr.pointee.size > 0,
               let mem = writerPtr.pointee.mem {
                result = CFDataCreate(kCFAllocatorDefault, mem, Int(writerPtr.pointee.size)).map { $0 as Data }
            }
            shim_WebPMemoryWriterClear(writerPtr)
        }
        return result
    }
}

// MARK: - encodeImage 主流程

func setErrorMessage(_ errBuf: UnsafeMutablePointer<CChar>?, _ size: Int32, _ message: String) {
    guard let errBuf, size > 0 else { return }
    let bytes = Array(message.utf8.prefix(Int(size) - 1))
    var i = 0
    for b in bytes { errBuf[i] = Int8(bitPattern: b); i += 1 }
    errBuf[i] = 0
}

func encodeImageImpl(rgba: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                     params: [String: Any], outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                     outLength: UnsafeMutablePointer<UInt>,
                     errBuf: UnsafeMutablePointer<CChar>?, errSize: Int32) -> Int32 {
    guard width > 0, height > 0, bytesPerRow >= width * 4 else {
        setErrorMessage(errBuf, errSize, "invalid pixel buffer"); return 1
    }

    let format = (params["format"] as? String) ?? "webp"
    let quality = max(1, min(100, (params["quality"] as? Double) ?? 82))
    let webpLossless = ((params["webpLossless"] as? Double) ?? 0) >= 0.5
    let pngMode = (params["pngMode"] as? String) ?? "truecolor"
    let colors = max(2, min(256, Int((params["colors"] as? Double) ?? 128)))
    let dither = ((params["dither"] as? Double) ?? 1) >= 0.5
    let scalePct = max(5, min(100, (params["scale"] as? Double) ?? 100))

    let srcBuffer = UnsafeBufferPointer(start: rgba, count: bytesPerRow * height)
    guard let srcImage = makeCGImage(from: Array(srcBuffer), width: width, height: height) else {
        setErrorMessage(errBuf, errSize, "cannot build CGImage"); return 2
    }
    let image: CGImage
    if scalePct < 100 {
        let nw = max(1, Int((Double(width) * scalePct / 100).rounded()))
        let nh = max(1, Int((Double(height) * scalePct / 100).rounded()))
        guard let scaled = resample(srcImage, toWidth: nw, toHeight: nh) else {
            setErrorMessage(errBuf, errSize, "cannot resample"); return 2
        }
        image = scaled
    } else {
        image = srcImage
    }

    let data: Data?
    switch format {
    case "webp":
        data = encodeWebP(image, quality: quality, lossless: webpLossless)
    case "jpeg":
        data = encodeJPEG(image, quality: quality / 100)
    case "png":
        if pngMode == "palette" {
            guard let (raw, w, h) = unpremultipliedRGBA(image),
                  let q = quantize(raw, width: w, height: h, maxColors: colors, dither: dither),
                  let png = writePNG8(q, width: w, height: h) else {
                setErrorMessage(errBuf, errSize, "png8 encode failed"); return 2
            }
            data = png
        } else {
            data = encodeWithImageIO(image, typeID: "public.png", quality: nil)
        }
    case "gif":
        guard let (raw, w, h) = unpremultipliedRGBA(image),
              let q = quantize(raw, width: w, height: h, maxColors: colors, dither: dither),
              let gif = writeGIF(q, width: w, height: h) else {
            setErrorMessage(errBuf, errSize, "gif encode failed"); return 2
        }
        data = gif
    default:
        setErrorMessage(errBuf, errSize, "unknown format: \(format)"); return 1
    }
    guard let data, !data.isEmpty else {
        setErrorMessage(errBuf, errSize, "encode produced no data"); return 2
    }

    let count = data.count
    let buffer = malloc(max(1, count)).assumingMemoryBound(to: UInt8.self)
    data.withUnsafeBytes { raw in
        memcpy(buffer, raw.baseAddress, count)
    }
    outData.pointee = buffer
    outLength.pointee = UInt(count)
    return 0
}

// MARK: - C ABI 入口

let entryIdentifier = strdup(pluginIdentifier)!
let entryName = strdup(pluginName)!
let entrySymbol = strdup(pluginSymbol)!
let entryParamsJSON = strdup(pluginParamsJSON)!

@_cdecl("compositor_plugin_main")
public func compositor_plugin_main(_ hostABI: UInt32) -> UnsafeMutableRawPointer {
    let encode: CompositorEncodeImageFn = { rgba, w, h, bpr, paramsJSON, outData, outLength, errBuf, errSize in
        guard let outData, let outLength else {
            setErrorMessage(errBuf, errSize, "null output pointer"); return 1
        }
        return encodeImageImpl(rgba: rgba, width: Int(w), height: Int(h), bytesPerRow: Int(bpr),
                               params: parseParams(paramsJSON), outData: outData, outLength: outLength,
                               errBuf: errBuf, errSize: errSize)
    }
    let entry = CompositorPluginEntry(
        abiVersion: 2,
        identifier: UnsafePointer(entryIdentifier),
        name: UnsafePointer(entryName),
        symbolName: UnsafePointer(entrySymbol),
        paramsJSON: UnsafePointer(entryParamsJSON),
        buildCutOutline: nil,
        encodeImage: encode)
    let box = UnsafeMutablePointer<CompositorPluginEntry>.allocate(capacity: 1)
    box.initialize(to: entry)
    return UnsafeMutableRawPointer(box)
}
