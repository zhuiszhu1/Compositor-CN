// CompositorPluginKit.swift — Compositor 插件宿主（ABI v1）
//
// 设计（2026-11-08）：
//   - 插件 = .compositorplugin bundle（Contents/MacOS/ 下一个动态库），放到
//     ~/Library/Application Support/Compositor/Plugins/ 或 App 包内 Contents/Plugins/。
//   - 主程序一次性内置插件宿主；效果算法与参数 schema 全在插件里 —— 以后新增效果
//     只编译插件，主程序不必重编。
//   - 接口是纯 C ABI（strdup 字符串 + 函数指针 + 两段式点集缓冲），跨 Swift 版本稳定，
//     插件与宿主之间不传任何 Swift 类型。
//   - v1 支持的插件类型：rectangleSelect —— 复用选框工具的拖框交互与光标，
//     Delete 键把插件生成的「撕掉区域」闭合轮廓从图层像素里 destinationOut 掉。
//
// ABI 契约（与撕边插件 TornEdgePlugin.swift 一致；v2 追加导出类函数）：
//   entry = dlsym("compositor_plugin_main")(hostABI)
//   struct CompositorPluginEntry {            // 手动偏移读取，跨 bundle 100% 稳定
//     UInt32 abiVersion;                       // @0
//     const char* identifier; const char* name; const char* symbolName;
//     const char* paramsJSON;                  // @8/16/24/32
//     int (*buildCutOutline)(rect*8f, paramsJSON, out*, inOutCount*) // @40  v1：撕边类
//     int (*encodeImage)(rgba*8, w, h, bytesPerRow, paramsJSON,  // @48  v2：导出类
//                        outData**, outLength*, errBuf, errSize) //  abiVersion >= 2 才有
//   }
//   v1 插件（撕边）继续有效：abiVersion=1 时只读 48 字节，encodeImage 视为 nil。

import AppKit
import Darwin

// MARK: - 参数 schema（插件 JSON → 宿主结构）

struct PluginParamSpec {
    let key: String
    let label: String
    let group: String
    let type: String                  // "float" | "int" | "choice"
    let min: Double
    let max: Double
    let defaultValue: Double
    let choices: [String]
    let choiceLabels: [String]
    let suffix: String
    let dice: Bool
}

struct PluginTool: Identifiable {
    let id: String                    // 插件 identifier
    let name: String
    let symbolName: String
    let interaction: String           // v1: "rectangleSelect"（画布工具）；v2: "export"（导出）
    let params: [PluginParamSpec]
    let buildCutOutline: CompositorBuildCutOutlineFn?
    let encodeImage: CompositorEncodeImageFn?
    let bundlePath: String
    /// 档位预设（schema 里 preset 参数的 presets 字段：档位名 → 参数值映射）。
    let presets: [String: [String: Any]]

    func params(in group: String) -> [PluginParamSpec] { params.filter { $0.group == group } }
    func spec(_ key: String) -> PluginParamSpec? { params.first { $0.key == key } }
    /// 是否为画布工具类插件（进左侧工具栏）。
    var isCanvasTool: Bool { interaction == "rectangleSelect" }
}

// MARK: - C ABI

typealias CompositorBuildCutOutlineFn = @convention(c) (
    _ rect: UnsafePointer<Float>,
    _ paramsJSON: UnsafePointer<CChar>?,
    _ outPoints: UnsafeMutablePointer<Float>?,
    _ ioCount: UnsafeMutablePointer<Int32>
) -> Int32

/// int encodeImage(const unsigned char* rgba, int w, int h, int bytesPerRow,
///                 const char* paramsJSON, unsigned char** outData, unsigned long* outLength,
///                 char* errBuf, int errBufSize)
/// 返回 0 成功（outData 为插件 malloc 的缓冲，宿主 free）/ 非 0 失败（errBuf 有英文说明）。
typealias CompositorEncodeImageFn = @convention(c) (
    _ rgba: UnsafePointer<UInt8>,
    _ width: Int32, _ height: Int32, _ bytesPerRow: Int32,
    _ paramsJSON: UnsafePointer<CChar>?,
    _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outLength: UnsafeMutablePointer<UInt>?,
    _ errBuf: UnsafeMutablePointer<CChar>?, _ errBufSize: Int32
) -> Int32

// MARK: - 插件管理器

@Observable
final class PluginManager {
    static let shared = PluginManager()
    private init() {}

    private var loadedTools: [PluginTool] = []
    private(set) var loadErrors: [String] = []
    private var loadedHandles: [UnsafeMutableRawPointer] = []
    /// 首次访问时加载（工具栏、激活状态、UI 都读它，无需别的启动接线）。
    private var didLoad = false
    var tools: [PluginTool] { ensureLoaded(); return loadedTools }

    /// 插件目录：用户目录优先，App 包内置随后（同名 identifier 先到先得）。
    static var searchURLs: [URL] {
        var urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .map { $0.appendingPathComponent("Compositor/Plugins", isDirectory: true) }
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Plugins", isDirectory: true))
        return urls
    }

    func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        loadPlugins()
    }

    private func loadPlugins() {
        for directory in Self.searchURLs {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where item.hasDirectoryPath {
                guard loadedTools.first(where: { $0.bundlePath == item.path }) == nil else { continue }
                _ = loadPlugin(at: item)
            }
        }
    }

    /// 单个插件的加载结果。启动扫描只关心成败；导入流程还要区分「identifier 重复」。
    private enum LoadOutcome {
        case loaded(PluginTool)   // 新加载成功，已追加进 loadedTools
        case duplicate            // identifier 已存在（先到先得挡下），文件保留
        case failed(String)       // 失败原因（同时已写入 loadErrors）
    }

    @discardableResult
    private func loadPlugin(at bundleURL: URL) -> LoadOutcome {
        // dlopen 支持 bundle 目录，但解析到可执行文件更明确，也便于报错。
        let executables = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            includingPropertiesForKeys: nil)) ?? []
        guard let executable = executables.first else {
            loadErrors.append("插件缺可执行文件：\(bundleURL.lastPathComponent)")
            return .failed("插件缺可执行文件（Contents/MacOS/ 为空）：\(bundleURL.lastPathComponent)")
        }
        guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) else {
            loadErrors.append("插件加载失败：\(bundleURL.lastPathComponent) — \(String(cString: dlerror()))")
            return .failed("插件加载失败：\(bundleURL.lastPathComponent) — \(String(cString: dlerror()))")
        }
        loadedHandles.append(handle)
        guard let symbol = dlsym(handle, "compositor_plugin_main") else {
            loadErrors.append("插件缺入口 compositor_plugin_main：\(bundleURL.lastPathComponent)")
            return .failed("插件缺入口 compositor_plugin_main：\(bundleURL.lastPathComponent)")
        }
        typealias MainFn = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
        let main = unsafeBitCast(symbol, to: MainFn.self)
        guard let entryPtr = main(1) else {
            loadErrors.append("插件入口返回空：\(bundleURL.lastPathComponent)")
            return .failed("插件入口返回空：\(bundleURL.lastPathComponent)")
        }
        // 手动偏移读取（见文件头 ABI 契约），不假设 Swift struct 跨 bundle 布局。
        // v1 = 48 字节（撕边）；v2 = 56 字节（追加 encodeImage @48）。
        let bytes = UnsafeRawBufferPointer(start: entryPtr, count: 56)
        let abi = bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let identifier = UnsafeRawPointer(bitPattern: bytes.loadUnaligned(fromByteOffset: 8, as: UInt.self))
            .map { UnsafePointer<CChar>(OpaquePointer($0)) }
        let name = UnsafeRawPointer(bitPattern: bytes.loadUnaligned(fromByteOffset: 16, as: UInt.self))
            .map { UnsafePointer<CChar>(OpaquePointer($0)) }
        let symbolName = UnsafeRawPointer(bitPattern: bytes.loadUnaligned(fromByteOffset: 24, as: UInt.self))
            .map { UnsafePointer<CChar>(OpaquePointer($0)) }
        let paramsJSON = UnsafeRawPointer(bitPattern: bytes.loadUnaligned(fromByteOffset: 32, as: UInt.self))
            .map { UnsafePointer<CChar>(OpaquePointer($0)) }
        let outlineFn = UnsafeRawPointer(bitPattern: bytes.loadUnaligned(fromByteOffset: 40, as: UInt.self))
        let encodeFn = abi >= 2
            ? UnsafeRawPointer(bitPattern: bytes.loadUnaligned(fromByteOffset: 48, as: UInt.self))
            : nil
        guard abi >= 1, let identifier, let name, let paramsJSON else {
            loadErrors.append("插件 ABI 不兼容：\(bundleURL.lastPathComponent)（abi=\(abi)）")
            return .failed("插件 ABI 不兼容：\(bundleURL.lastPathComponent)（abi=\(abi)，本机宿主支持 v1/v2）")
        }
        let schema = (try? JSONSerialization.jsonObject(with: Data(bytes: paramsJSON, count: strlen(paramsJSON))))
            as? [String: Any]
        guard let schema else {
            loadErrors.append("插件参数 schema 不是合法 JSON：\(bundleURL.lastPathComponent)")
            return .failed("插件参数 schema 不是合法 JSON：\(bundleURL.lastPathComponent)")
        }
        let specs = Self.parseParams(schema["params"] as? [[String: Any]] ?? [])
        // preset 参数的 presets 字段：{ 档位名: { 参数 key: 值 } }
        let presets: [String: [String: Any]] = (schema["params"] as? [[String: Any]] ?? [])
            .first(where: { $0["key"] as? String == "preset" })?["presets"] as? [String: [String: Any]] ?? [:]
        let tool = PluginTool(
            id: String(cString: identifier),
            name: String(cString: name),
            symbolName: symbolName.map { String(cString: $0) } ?? "puzzlepiece.extension",
            interaction: schema["interaction"] as? String ?? "rectangleSelect",
            params: specs,
            buildCutOutline: outlineFn.map {
                unsafeBitCast(OpaquePointer($0), to: CompositorBuildCutOutlineFn.self)
            },
            encodeImage: encodeFn.map {
                unsafeBitCast(OpaquePointer($0), to: CompositorEncodeImageFn.self)
            },
            bundlePath: bundleURL.path,
            presets: presets)
        if loadedTools.contains(where: { $0.id == tool.id }) { return .duplicate } // 先到先得
        loadedTools.append(tool)
        return .loaded(tool)
    }

    // MARK: 导入插件（左侧工具栏底部「导入插件」按钮）

    /// 导入结果，供 UI 反馈。
    enum ImportOutcome {
        /// 新插件：已复制进插件目录、已加载并追加进 tools，UI 立即可用。
        case added(PluginTool)
        /// 同 identifier 的插件已在运行态：新文件已放进用户插件目录，重启后按「用户目录优先」加载新版。
        case updated
        /// 导入失败（已回滚：刚复制的文件删除，被覆盖的旧目录还原）。
        case failed(String)
    }

    /// 把选中的 .compositorplugin 复制进沙盒容器的插件目录
    /// （Application Support/Compositor/Plugins/，用户目录优先于 App 包内置），然后立即加载。
    /// 同名目录 = 更新：旧目录先挪进容器临时区备份，加载失败时原样还原。
    @discardableResult
    func importPlugin(from source: URL) -> ImportOutcome {
        guard source.hasDirectoryPath, source.pathExtension == "compositorplugin" else {
            return .failed("不是 .compositorplugin 插件包：\(source.lastPathComponent)")
        }
        let fm = FileManager.default
        let directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compositor/Plugins", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed("创建插件目录失败：\(error.localizedDescription)")
        }
        let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        // 备份放容器临时区而非 Plugins/（.backup 目录会混进启动时的插件扫描）。
        var backup: URL?
        if fm.fileExists(atPath: destination.path) {
            backup = fm.temporaryDirectory.appendingPathComponent(source.lastPathComponent + ".backup")
            do {
                try? fm.removeItem(at: backup!)
                try fm.moveItem(at: destination, to: backup!)
            } catch {
                return .failed("备份旧插件失败：\(error.localizedDescription)")
            }
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            if let backup { try? fm.moveItem(at: backup, to: destination) } // 还原旧版
            return .failed("复制插件失败：\(error.localizedDescription)")
        }
        switch loadPlugin(at: destination) {
        case .loaded(let tool):
            if let backup { try? fm.removeItem(at: backup) }
            return .added(tool)
        case .duplicate:
            // 运行态已加载同一 identifier：dyld 对已加载的 dylib 只返回旧 handle，
            // 新文件留在用户插件目录即可，重启后按用户目录优先生效。
            if let backup { try? fm.removeItem(at: backup) }
            return .updated
        case .failed(let reason):
            try? fm.removeItem(at: destination)                             // 坏插件不留在容器里
            if let backup { try? fm.moveItem(at: backup, to: destination) } // 还原被覆盖的旧版
            return .failed(reason)
        }
    }

    private static func parseParams(_ list: [[String: Any]]) -> [PluginParamSpec] {
        list.compactMap { item in
            guard let key = item["key"] as? String, let type = item["type"] as? String else { return nil }
            let choices = item["choices"] as? [String] ?? []
            let choiceLabels = item["choiceLabels"] as? [String] ?? choices
            // choice 的 default 是选项字符串（如 "standard"），映射回选项索引；数值/缺失沿用原逻辑。
            let number: Double
            if type == "choice", let string = item["default"] as? String,
               let index = choices.firstIndex(of: string) {
                number = Double(index)
            } else {
                number = item["default"] as? Double
                    ?? (item["default"] as? String).flatMap(Double.init)
                    ?? 0
            }
            return PluginParamSpec(
                key: key, label: item["label"] as? String ?? key,
                group: item["group"] as? String ?? "shared", type: type,
                min: item["min"] as? Double ?? 0, max: item["max"] as? Double ?? 100,
                defaultValue: number, choices: choices, choiceLabels: choiceLabels,
                suffix: item["suffix"] as? String ?? "",
                dice: item["dice"] as? Bool ?? false)
        }
    }

    func tool(id: String?) -> PluginTool? {
        ensureLoaded()
        guard let id else { return nil }
        return tools.first { $0.id == id }
    }

    // MARK: 参数值（内存缓存驱动 UI；UserDefaults 持久化；choice 存选项索引）

    /// 运行时参数值缓存。必须先于/独立于 UserDefaults：滑杆等受控控件拖动时走
    /// set → 这里（@Observable 跟踪到）→ body 重算 → get 读回新值，控件才会动。
    /// 直读直写 UserDefaults 绕开观察跟踪，控件会完全冻结（2026-11-08 实测）。
    private var runtimeValues: [String: Double] = [:]

    func value(for tool: PluginTool, key: String) -> Double {
        let storageKey = "pluginTool.\(tool.id).\(key)"
        if let cached = runtimeValues[storageKey] { return cached }
        let spec = tool.spec(key)
        let value: Double
        if UserDefaults.standard.object(forKey: storageKey) == nil {
            value = spec?.defaultValue ?? 0
        } else {
            value = UserDefaults.standard.double(forKey: storageKey)
        }
        runtimeValues[storageKey] = value
        return value
    }

    func setValue(_ value: Double, for tool: PluginTool, key: String) {
        let storageKey = "pluginTool.\(tool.id).\(key)"
        runtimeValues[storageKey] = value
        UserDefaults.standard.set(value, forKey: storageKey)
    }

    /// 当前参数值 → 插件 JSON（choice 索引映射回选项字符串）。
    /// `layerBounds` 为图层可见像素边界（文档坐标），随参数注入（lb0-lb3）——
    /// 插件据此把与图层边缘齐平的选框边变成直线全像素裁切（单边撕边）。
    func paramsJSON(for tool: PluginTool, layerBounds: CGRect? = nil) -> String {
        var object: [String: Any] = [:]
        for spec in tool.params {
            let value = value(for: tool, key: spec.key)
            if spec.type == "choice", spec.choices.indices.contains(Int(value)) {
                object[spec.key] = spec.choices[Int(value)]
            } else if spec.type == "int" {
                object[spec.key] = Int(value)
            } else {
                object[spec.key] = value
            }
        }
        if let bounds = layerBounds {
            object["lb0"] = bounds.minX
            object["lb1"] = bounds.minY
            object["lb2"] = bounds.maxX
            object["lb3"] = bounds.maxY
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: 导出编码（ABI v2，可在后台线程调用）

    /// 同步调用导出插件的 encodeImage：RGBA8 预乘像素 + 参数 JSON → 编码结果。
    /// 插件 malloc 的缓冲拷贝为 Data 后立即 free。不触 MainActor 状态，后台 Task 可直接调。
    /// 失败返回 (nil, 英文错误说明)。
    nonisolated static func encodeWithPlugin(_ encode: CompositorEncodeImageFn,
                                             rgba: UnsafePointer<UInt8>,
                                             width: Int, height: Int, bytesPerRow: Int,
                                             values: String) -> (data: Data?, error: String?) {
        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outLen: UInt = 0
        var errBuf = [CChar](repeating: 0, count: 256)
        let rc = values.withCString { json in
            encode(rgba, Int32(width), Int32(height), Int32(bytesPerRow), json,
                   &outPtr, &outLen, &errBuf, 256)
        }
        guard rc == 0, let ptr = outPtr, outLen > 0 else {
            let message = String(cString: errBuf)
            return (nil, message.isEmpty ? "encodeImage rc=\(rc)" : message)
        }
        defer { free(ptr) }
        return (Data(bytes: ptr, count: Int(outLen)), nil)
    }

    /// 选框矩形 → 插件生成的「撕掉区域」闭合轮廓点集（文档坐标）。
    func cutOutlinePoints(documentRect: CGRect, tool: PluginTool, values: String) -> [CGPoint]? {
        guard let build = tool.buildCutOutline else { return nil }
        let rect: [Float] = [
            Float(documentRect.minX), Float(documentRect.minY),
            Float(documentRect.maxX), Float(documentRect.minY),
            Float(documentRect.maxX), Float(documentRect.maxY),
            Float(documentRect.minX), Float(documentRect.maxY),
        ]
        var count: Int32 = 0
        var result: [Float] = []
        let ok = values.withCString { json in
            build(rect, json, nil, &count) == 0
        }
        guard ok, count > 0, count < 8_000_000 else { return nil }
        result = [Float](repeating: 0, count: Int(count) * 2)
        var capacity = count
        let rc = result.withUnsafeMutableBufferPointer { buffer -> Int32 in
            values.withCString { json in
                build(rect, json, buffer.baseAddress, &capacity)
            }
        }
        guard rc == 0, capacity > 0 else { return nil }
        return stride(from: 0, to: Int(capacity) * 2, by: 2).map { CGPoint(x: CGFloat(result[$0]), y: CGFloat(result[$0 + 1])) }
    }
}
