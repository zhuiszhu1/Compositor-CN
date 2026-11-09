// ExportPluginSheet.swift — 导出类插件（ABI v2 export）的导出对话框
//
// 与 ExportAsSheet 同一套预览框架（JPEGPreview + 后台编码 + 真实大小显示），
// 参数区由插件的 params schema 驱动（PluginManager 持久化），编码走插件的 encodeImage。
//
// 档位（preset）行为：
//   - 切档位 → 宿主把该档位 presets 里的参数批量写入（custom 档为空，仅切换自身）；
//   - 手动改任一预设参数 → 与当前档位预设值不符时自动跳到 custom（相符则保持）。
//
// 基准对比：打开时用 ImageIO 编一份全彩 PNG 作参照，随结果显示「PNG 参照 → 当前（省 X%）」。

import SwiftUI
import ImageIO

struct ExportPluginSheet: View {
    let raster: ExportRaster
    let tool: PluginTool
    let session: EditorSession
    let finish: (Data?) -> Void

    @State private var result: Encoded?
    @State private var error: String?
    @State private var baselineSize: Int?
    @State private var suppressAutoCustom = false
    /// 渲染像素（RGBA8 预乘，打开时画一次，编码任务复用）。
    @State private var pixels: [UInt8]?
    private var isReady: Bool { result?.settings == settingsHash && error == nil }
    @Environment(\.displayScale) private var displayScale

    private var manager: PluginManager { PluginManager.shared }
    /// 参与编码的参数快照（任一变化重编预览）。
    /// ⚠️ 必须用键序固定的拼接串，不能用 paramsJSON（JSONSerialization）的输出做 .task(id:)：
    /// 新版 Foundation 对字典键序做了轮换随机化（2026-11-09 实测同内容两次输出键序不同），
    /// id 每帧都在变 → task 反复取消、编码结果反复被丢弃 → 预览永远「正在更新…」。
    private var settingsHash: String {
        tool.params.map { "\($0.key)=\(manager.value(for: tool, key: $0.key))" }.joined(separator: "|")
    }

    private var formatSpec: PluginParamSpec? { tool.spec("format") }
    private var format: String {
        let index = Int(manager.value(for: tool, key: "format"))
        return formatSpec?.choices.indices.contains(index) == true ? formatSpec!.choices[index] : "webp"
    }
    private func choiceValue(_ key: String) -> String {
        guard let spec = tool.spec(key) else { return "" }
        let index = Int(manager.value(for: tool, key: key))
        return spec.choices.indices.contains(index) ? spec.choices[index] : ""
    }

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(L(tool.name)).font(.title2.bold())
                Spacer()
                Button("Fit") { previewZoom = nil }
                    .disabled(previewZoom == nil).help(L("Show the whole image (⌘0)"))
                Button { zoomBy(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: 1) == nil)
                    .help(String.localizedStringWithFormat(L("Zoom in (⌘+), now %@"), percent))
                Button { zoomBy(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: -1) == nil)
                    .help(String.localizedStringWithFormat(L("Zoom out (⌘−), now %@"), percent))
            }
            .padding(.bottom, -8)
            ZStack {
                Color(white: 0.12)
                if let result {
                    JPEGPreview(image: result.preview, pixelWidth: raster.image.width,
                                pixelHeight: raster.image.height, zoom: $previewZoom)
                }
                if !isReady && error == nil {
                    ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(width: JPEGPreview.frame.width, height: JPEGPreview.frame.height).clipped()
                .help(L("Drag or scroll to move around; double-click switches between Fit and 100%."))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Format")
                    choiceSegmented("format")
                }
                GridRow {
                    Text("Preset")
                    presetSegmented
                }
                GridRow {
                    Text("Scale")
                    HStack(spacing: 6) {
                        AppSlider(value: numberBinding("scale"), in: 5...100).frame(width: 220)
                        numberField("scale", width: 48)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                if format == "webp" || format == "jpeg" {
                    GridRow {
                        Text("Quality")
                        HStack {
                            AppSlider(value: numberBinding("quality"), in: 1...100).frame(width: 300)
                            numberField("quality", width: 45)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                }
                if format == "webp" {
                    GridRow {
                        Text("Lossless")
                        Toggle(L("Keep every pixel exactly"), isOn: losslessBinding)
                            .help(L("WebP lossless keeps every pixel exactly, in a larger file"))
                    }
                }
                if format == "png" {
                    GridRow {
                        Text("PNG Mode")
                        choiceSegmented("pngMode")
                    }
                }
                if format == "gif" || (format == "png" && choiceValue("pngMode") == "palette") {
                    GridRow {
                        Text("Colors")
                        HStack(spacing: 6) {
                            AppSlider(value: numberBinding("colors"), in: 2...256).frame(width: 220)
                            numberField("colors", width: 48)
                        }
                    }
                    GridRow {
                        Text("Dither")
                        Toggle(L("Floyd–Steinberg"), isOn: ditherBinding)
                            .help(L("Dithering spreads quantization error for smoother gradients; off gives cleaner flat colors"))
                    }
                }
            }
            HStack(spacing: 12) {
                if let baseline = baselineSize {
                    Text(L("PNG reference") + " "
                         + ByteCountFormatter.string(fromByteCount: Int64(baseline), countStyle: .file)
                         + (result != nil ? " · " + String.localizedStringWithFormat(L("saves %d%%"), savingPercent(baseline: baseline, current: result!.data.count)) : ""))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if isReady, let result {
                    Text(L(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))).monospacedDigit()
                } else if error == nil {
                    Text(L("Updating…")).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Cancel") { finish(nil) }.configuredNativeShortcut(.escape)
                Button("Export…") {
                    if let result { finish(result.data) } else { finish(nil) }
                }
                .configuredNativeShortcut(.return)
                .disabled(!isReady)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).frame(maxWidth: JPEGPreview.frame.width, alignment: .leading) }
        }
        .padding(24)
        .onAppear {
            session.previewZoom = { command in
                switch command {
                case .zoomIn: zoomBy(1)
                case .zoomOut: zoomBy(-1)
                case .fit: previewZoom = nil
                case .actual: previewZoom = 1
                }
            }
            let width = raster.image.width, height = raster.image.height
            // 渲染像素画一次（编码任务复用）。
            pixels = renderPixels()
            // 基准：ImageIO 全彩 PNG 的体积（后台一次）。
            Task.detached(priority: .userInitiated) {
                let data = try? await ImageExporter.shared.pngData(raster)
                if let size = data?.count {
                    await MainActor.run { baselineSize = size }
                }
            }
        }
        .onDisappear { session.previewZoom = nil }
        .task(id: settingsHash) {
            // 参数变化 → 后台真实编码预览（debounce 300ms）。
            let requested = settingsHash
            error = nil
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, requested == settingsHash, let encode = tool.encodeImage,
                  let pixels, pixels.count == raster.image.width * raster.image.height * 4 else {
                // 参数又变了（新一代 task 接管）是正常取消；其余失败必须可见，绝不静默转圈
                //（v4.2 卡死事故的教训：编码链路的任何 guard 失败都不能无声吞掉）。
                if !Task.isCancelled { error = L("The preview could not be generated.") }
                return
            }
            let width = raster.image.width, height = raster.image.height
            // 编码 JSON 与比较快照分离：插件按 key 解析，JSONSerialization 的键序随机无碍；
            // 比较/持久化用 settingsHash（键序固定）。
            let values = manager.paramsJSON(for: tool)
            let outcome: (data: Data?, error: String?) = await Task.detached(priority: .userInitiated) {
                pixels.withUnsafeBufferPointer { buffer in
                    PluginManager.encodeWithPlugin(encode, rgba: buffer.baseAddress!,
                                                   width: width, height: height, bytesPerRow: width * 4,
                                                   values: values)
                }
            }.value
            guard !Task.isCancelled, requested == settingsHash else { return }
            if let data = outcome.data {
                let preview: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 8192),
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
                }.value
                guard !Task.isCancelled, requested == settingsHash else { return }
                if let preview {
                    result = Encoded(data: data, preview: preview, settings: requested)
                } else {
                    error = L("The image could not be decoded for preview.")
                }
            } else {
                error = outcome.error ?? "encode failed"
            }
        }
    }

    struct Encoded {
        let data: Data
        let preview: CGImage
        let settings: String
    }

    /// 渲染 raster 为 RGBA8 预乘像素。
    private func renderPixels() -> [UInt8] {
        let width = raster.image.width, height = raster.image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(raster.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    // MARK: 控件

    private func choiceSegmented(_ key: String) -> some View {
        guard let spec = tool.spec(key) else { return AnyView(EmptyView()) }
        return AnyView(
            Picker(spec.label, selection: choiceBinding(key)) {
                ForEach(spec.choices.indices, id: \.self) { index in
                    Text(LocalizedStringKey(spec.choiceLabels[index])).tag(Double(index))
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(L(tool.name) + " — " + L(spec.label)))
    }

    /// 档位：切换时批量填参。
    private var presetSegmented: some View {
        let spec = tool.spec("preset")
        return Picker(spec?.label ?? "Preset", selection: presetBinding) {
            ForEach((spec?.choices.indices ?? 0..<0), id: \.self) { index in
                Text(LocalizedStringKey(spec?.choiceLabels[index] ?? "")).tag(Double(index))
            }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help(L(tool.name) + " — " + L("Preset"))
    }

    @ViewBuilder private func numberField(_ key: String, width: CGFloat) -> some View {
        if let spec = tool.spec(key) {
            TextField(L(spec.label), value: numberBinding(key),
                      format: spec.type == "float" && spec.max <= 10
                          ? .number.precision(.fractionLength(0...1)) : .number.precision(.fractionLength(0)))
                .frame(width: width).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { manager.value(for: tool, key: key) },
                            change: { manager.setValue(clamped($0, spec), for: tool, key: key); parameterChanged(key) })
        }
    }

    private func clamped(_ value: Double, _ spec: PluginParamSpec) -> Double {
        min(max(value, spec.min), max(spec.min, spec.max))
    }

    private func numberBinding(_ key: String) -> Binding<Double> {
        guard let spec = tool.spec(key) else { return .constant(0) }
        return Binding(
            get: { clamped(manager.value(for: tool, key: key), spec) },
            set: { manager.setValue(clamped($0, spec), for: tool, key: key); parameterChanged(key) })
    }

    private var losslessBinding: Binding<Bool> {
        Binding(get: { manager.value(for: tool, key: "webpLossless") >= 0.5 },
                set: { manager.setValue($0 ? 1 : 0, for: tool, key: "webpLossless"); parameterChanged("webpLossless") })
    }
    private var ditherBinding: Binding<Bool> {
        Binding(get: { manager.value(for: tool, key: "dither") >= 0.5 },
                set: { manager.setValue($0 ? 1 : 0, for: tool, key: "dither"); parameterChanged("dither") })
    }

    private func choiceBinding(_ key: String) -> Binding<Double> {
        guard let spec = tool.spec(key) else { return .constant(0) }
        return Binding(
            get: { manager.value(for: tool, key: key) },
            set: {
                manager.setValue(min(max($0, 0), Double(max(spec.choices.count - 1, 0))), for: tool, key: key)
                parameterChanged(key)
            })
    }

    private var presetBinding: Binding<Double> {
        guard let spec = tool.spec("preset") else { return .constant(0) }
        return Binding(
            get: { manager.value(for: tool, key: "preset") },
            set: {
                manager.setValue(min(max($0, 0), Double(max(spec.choices.count - 1, 0))), for: tool, key: "preset")
                applyPreset(at: Int($0))
            })
    }

    /// 档位切换 → 批量写入该档位预设参数（choice 值是字符串，映射回索引）。
    private func applyPreset(at index: Int) {
        guard let spec = tool.spec("preset"), spec.choices.indices.contains(index) else { return }
        let name = spec.choices[index]
        guard name != "custom", let values = tool.presets[name] else { return }
        suppressAutoCustom = true
        defer { suppressAutoCustom = false }
        for (key, value) in values {
            guard let paramSpec = tool.spec(key) else { continue }
            if paramSpec.type == "choice", let string = value as? String,
               let idx = paramSpec.choices.firstIndex(of: string) {
                manager.setValue(Double(idx), for: tool, key: key)
            } else if let number = value as? Double {
                manager.setValue(clamped(number, paramSpec), for: tool, key: key)
            } else if let number = value as? Int {
                manager.setValue(clamped(Double(number), paramSpec), for: tool, key: key)
            }
        }
    }

    /// 手动改预设参数 → 与当前档位预设不符时跳 custom；相符保持（切档自动填参不触发）。
    private func parameterChanged(_ key: String) {
        guard !suppressAutoCustom, key != "preset", key != "format" else { return }
        guard let presetSpec = tool.spec("preset") else { return }
        let presetIndex = Int(manager.value(for: tool, key: "preset"))
        guard presetSpec.choices.indices.contains(presetIndex) else { return }
        let presetName = presetSpec.choices[presetIndex]
        guard presetName != "custom", let presetValues = tool.presets[presetName] else { return }
        guard let expected = presetValues[key] else { return } // 预设未含此参数 → 不跳档
        let current = manager.value(for: tool, key: key)
        let spec = tool.spec(key)
        let matches: Bool
        if spec?.type == "choice", let string = expected as? String {
            matches = string == choiceValue(key)
        } else if let number = expected as? Double {
            matches = abs(number - current) < 0.001
        } else if let number = expected as? Int {
            matches = abs(Double(number) - current) < 0.001
        } else {
            matches = false
        }
        if !matches {
            let customIndex = Double(presetSpec.choices.firstIndex(of: "custom") ?? 0)
            manager.setValue(customIndex, for: tool, key: "preset")
        }
    }

    // MARK: 预览缩放（与 ExportAsSheet 同规则）

    @State private var previewZoom: Double?
    private var shownZoom: Double {
        previewZoom ?? JPEGPreview.fitZoom(width: raster.image.width, height: raster.image.height,
                                           in: JPEGPreview.frame, displayScale: displayScale)
    }
    private var percent: String { "\(Int((shownZoom * 100).rounded()))%" }
    private func zoomBy(_ direction: Int) {
        if let next = JPEGPreview.step(from: shownZoom, in: direction) { previewZoom = next }
    }

    private func savingPercent(baseline: Int, current: Int) -> Int {
        guard baseline > 0, current < baseline else { return 0 }
        return Int((1.0 - Double(current) / Double(baseline)) * 100)
    }

    /// 导出格式对应的文件扩展名（保存面板用）。
    static func fileExtension(format: String) -> String {
        switch format {
        case "webp": return "webp"
        case "jpeg": return "jpg"
        case "png": return "png"
        case "gif": return "gif"
        default: return "webp"
        }
    }
}
