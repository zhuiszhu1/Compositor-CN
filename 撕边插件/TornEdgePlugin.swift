// TornEdgePlugin.swift — Compositor「撕边」插件
//
// C ABI 插件契约（与主程序 Plugins/CompositorPluginKit.swift 保持一致，ABI v1）：
//   入口：compositor_plugin_main(hostABI) → 指向 CompositorPluginEntry 的指针（宿主释放语义：进程期存活，不释放）
//   职责：框选删除类效果 —— 根据选框几何与参数，生成「撕掉区域」的闭合轮廓点集。
//        主程序负责把点集转 CGPath、destinationOut 撕掉图层像素、进撤销历史。
//   点集：Float 数组，(x,y) 交错；顺序 = 上边 → 右边 → 下边 → 左边（顺时针环绕），
//        宿主 fillPath 自动闭合（相邻边端点间隙由填充规则自然衔接）。
//   两段式调用：第一次 outPoints=nil 返回所需点数；宿主按数分配后第二次取点。
//        算法完全由种子决定，两次调用结果逐点一致。
//
// 算法移植自 torn_paper_edge.py（2026-11-08 目检定稿的
// rough/fine 两档手感），通用化为「沿任意基线段的法向撕口」：
//   rough：大尺度控制点插值 + 中频局部起伏 + 逐列微毛刺 + 圆滑钟形纤维缺口
//   fine ：慢漂移 + 白噪声高斯平滑圆钝小齿 + 逐列微毛刺 + 准周期中频波（大线条频率）
// 纯数学算法，无 AI、无网络、无 Foundation 依赖（手写参数解析），stdlib 静态链接。

import Darwin

// MARK: - C ABI v1（宿主与插件共同遵守的稳定接口）

public typealias CompositorBuildCutOutlineFn = @convention(c) (
    _ rect: UnsafePointer<Float>,          // 8 floats: x0,y0, x1,y0, x1,y1, x0,y1（顺时针四角）
    _ paramsJSON: UnsafePointer<CChar>?,   // 参数值对象，如 {"profile":"rough","seed":20261108}
    _ outPoints: UnsafeMutablePointer<Float>?, // (x,y) 交错点集；nil = 查询所需数量
    _ ioCount: UnsafeMutablePointer<Int32>     // 入：缓冲容量（点数）；出：实际点数
) -> Int32                                   // 0 成功；1 参数错误；2 缓冲不足（出参回填所需数量）

public struct CompositorPluginEntry {
    public var abiVersion: UInt32
    public var identifier: UnsafePointer<CChar>
    public var name: UnsafePointer<CChar>
    public var symbolName: UnsafePointer<CChar>
    public var paramsJSON: UnsafePointer<CChar>   // 参数 schema（宿主渲染配置 UI）
    public var buildCutOutline: CompositorBuildCutOutlineFn?
    public init(abiVersion: UInt32, identifier: UnsafePointer<CChar>, name: UnsafePointer<CChar>,
                symbolName: UnsafePointer<CChar>, paramsJSON: UnsafePointer<CChar>,
                buildCutOutline: CompositorBuildCutOutlineFn?) {
        self.abiVersion = abiVersion; self.identifier = identifier; self.name = name
        self.symbolName = symbolName; self.paramsJSON = paramsJSON
        self.buildCutOutline = buildCutOutline
    }
}

let kHostABI: UInt32 = 1

// MARK: - 插件元数据与参数 schema

let pluginIdentifier = "torn-edge"
let pluginName = "Torn Edge"
let pluginSymbol = "scissors"

// 分组规则：group = rough / fine / shared。profile 当前值决定显示哪组参数 + shared 组。
// 参数值语义为文档像素（撕口几何在文档坐标系生成）。
let pluginParamsJSON = """
{
  "interaction": "rectangleSelect",
  "params": [
    {"key":"profile","label":"Style","group":"shared","type":"choice","choices":["rough","fine"],
     "choiceLabels":["Rough","Fine"],"default":"rough"},
    {"key":"roughAmp","label":"Amplitude","group":"rough","type":"float","min":0,"max":120,"default":42,"suffix":"px"},
    {"key":"roughGap","label":"Line Spacing","group":"rough","type":"float","min":80,"max":600,"default":260,"suffix":"px"},
    {"key":"roughMid","label":"Local Waves","group":"rough","type":"float","min":0,"max":40,"default":9,"suffix":"px"},
    {"key":"roughFibers","label":"Fiber Gaps","group":"rough","type":"int","min":0,"max":40,"default":20},
    {"key":"fineAmp","label":"Amplitude","group":"fine","type":"float","min":0,"max":60,"default":7,"suffix":"px"},
    {"key":"fineWaves","label":"Line Frequency","group":"fine","type":"float","min":0,"max":30,"default":14,"suffix":"/950px"},
    {"key":"fineTooth","label":"Teeth","group":"fine","type":"float","min":0,"max":6,"default":1.3,"suffix":"px"},
    {"key":"fineWaveGap","label":"Wave Spacing","group":"fine","type":"float","min":120,"max":600,"default":340,"suffix":"px"},
    {"key":"micro","label":"Fuzz","group":"shared","type":"float","min":0,"max":3,"default":0.7,"suffix":"px"},
    {"key":"seed","label":"Seed","group":"shared","type":"int","min":0,"max":99999999,"default":20261108,"dice":true}
  ]
}
"""

// MARK: - 极简参数解析（扁平 JSON 对象，值仅 string / 整数 / 小数）

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
        i = s.index(after: i) // 跳过结束引号
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

// MARK: - 随机数（SplitMix64 种子流，同参数同种子可复现）

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// [lo, hi) 均匀分布（53 位精度）。
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        let u = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return lo + u * (hi - lo)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        guard hi > lo else { return lo }
        return lo + Int(next() % UInt64(hi - lo))
    }
}

// MARK: - 一维高斯平滑（对应 Python _smooth1d，输出等长）

private func smooth1d(_ v: [Double], sigma: Double) -> [Double] {
    guard sigma > 0, !v.isEmpty else { return v }
    let r = max(1, Int(3 * sigma + 0.5))
    var kernel = [Double](repeating: 0, count: 2 * r + 1)
    var sum = 0.0
    for k in -r...r {
        let w = exp(-0.5 * pow(Double(k) / sigma, 2))
        kernel[k + r] = w; sum += w
    }
    for i in kernel.indices { kernel[i] /= sum }
    var result = [Double](repeating: 0, count: v.count)
    for i in v.indices {
        var acc = 0.0
        for k in -r...r {
            let j = min(max(i + k, 0), v.count - 1)
            acc += v[j] * kernel[k + r]
        }
        result[i] = acc
    }
    return result
}

private func stdOf(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    var acc = 0.0
    for x in v { acc += x * x }
    return sqrt(acc / Double(v.count))
}

// MARK: - 撕口轮廓（rough 档，对应 Python tear_curve）

private func tearProfileRough(length: Int, amp: Double, gap: Double, mid: Double,
                              micro: Double, fibers: Int, rng: inout SplitMix64) -> [Double] {
    let W = max(2, length)
    var y = [Double](repeating: 0, count: W)
    // 大尺度：间距约 gap 的不等距控制点插值，缓慢起伏、无周期性。
    let n = max(5, W / Int(max(40, gap)))
    var cx = [Double](repeating: 0, count: n + 2)
    var run = 0.0
    for i in 1...n { run += rng.uniform(gap * 0.7, gap * 1.4); cx[i] = run }
    let total = max(cx[n], 1e-9)
    for i in 1...n { cx[i] = cx[i] / total * Double(W - 1) }
    cx[n + 1] = Double(W - 1)
    var cy = [Double](repeating: 0, count: n + 2)
    for i in cy.indices { cy[i] = rng.uniform(-amp, amp) }
    interp(into: &y, xs: cx, ys: cy)
    // 中频：局部起伏，控制点间距 16~42px。
    let n2 = W / 32 + 3
    var cx2 = [Double](repeating: 0, count: n2 + 2)
    run = 0
    for i in 1...n2 { run += rng.uniform(16, 42); cx2[i] = run }
    let total2 = max(cx2[n2], 1e-9)
    for i in 1...n2 { cx2[i] = cx2[i] / total2 * Double(W - 1) }
    cx2[n2 + 1] = Double(W - 1)
    var cy2 = [Double](repeating: 0, count: n2 + 2)
    for i in cy2.indices { cy2[i] = rng.uniform(-mid, mid) }
    var mid2 = [Double](repeating: 0, count: W)
    interp(into: &mid2, xs: cx2, ys: cy2)
    for x in 0..<W { y[x] += mid2[x] }
    // 高频：逐列纸纤维毛刺。
    for x in 0..<W { y[x] += rng.uniform(-micro, micro) }
    // 纤维撕裂缺口：数量少、宽度大、峰位随机偏斜的圆滑钟形（对称尖三角会被看成电锯切口）。
    for _ in 0..<fibers {
        guard W > 40 else { break }
        let i = rng.int(20, W - 20)
        let half = rng.int(4, 13)
        let h = (rng.next() & 1 == 0 ? -1.0 : 1.0) * rng.uniform(8, 16)
        let lo = max(0, i - half), hi = min(W - 1, i + half + 1)
        let peak = rng.uniform(0.35, 0.65)
        for k in lo...hi {
            let t = Double(k - lo) / Double(max(2 * half, 1))
            let shape: Double
            if t < peak { shape = pow(t / peak, 0.8) }
            else { shape = pow(max(min((1.0 - t) / (1.0 - peak), 1.0), 0.0), 1.4) }
            y[k] += h * shape
        }
    }
    let bound = max(6.0, amp * 1.7)
    for x in 0..<W { y[x] = min(max(y[x], -bound), bound) }
    return y
}

/// 控制点线性插值到每列（对应 np.interp；xs 升序，首点 x=0、末点 x=W-1）。
private func interp(into out: inout [Double], xs: [Double], ys: [Double]) {
    let W = out.count
    var j = 0
    for x in 0..<W {
        let px = Double(x)
        while j < xs.count - 2 && xs[j + 1] < px { j += 1 }
        let span = max(xs[j + 1] - xs[j], 1e-9)
        let t = min(max((px - xs[j]) / span, 0), 1)
        out[x] += ys[j] + t * (ys[j + 1] - ys[j])
    }
}

// MARK: - 撕口轮廓（fine 档，对应 Python tear_curve_fine + mid_wave）

private func tearProfileFine(length: Int, amp: Double, tooth: Double, sigma: Double,
                             waveGap: Double, midWaves: Double, micro: Double,
                             seed: UInt64, rng: inout SplitMix64) -> [Double] {
    let W = max(2, length)
    var y = [Double](repeating: 0, count: W)
    // 极缓慢的大尺度漂移：控制点平均间距 waveGap（调小 = 波数更多、大线条更连续）。
    let n = max(4, Int(Double(W) / max(60, waveGap)))
    var cx = [Double](repeating: 0, count: n + 2)
    var run = 0.0
    for i in 1...n { run += rng.uniform(waveGap * 0.65, waveGap * 1.3); cx[i] = run }
    let total = max(cx[n], 1e-9)
    for i in 1...n { cx[i] = cx[i] / total * Double(W - 1) }
    cx[n + 1] = Double(W - 1)
    var cy = [Double](repeating: 0, count: n + 2)
    for i in cy.indices { cy[i] = rng.uniform(-amp, amp) }
    interp(into: &y, xs: cx, ys: cy)
    // 细密圆钝小齿：噪声高斯平滑后归一化 std=1，乘 tooth（逐列噪声必须显著小于小齿）。
    var noise = [Double](repeating: 0, count: W)
    for x in 0..<W { noise[x] = rng.uniform(-1, 1) }
    noise = smooth1d(noise, sigma: sigma)
    let scale = tooth / max(stdOf(noise), 1e-6)
    for x in 0..<W { y[x] += noise[x] * scale }
    // 逐列极细纸纤维噪声。
    for x in 0..<W { y[x] += rng.uniform(-micro, micro) }
    // 准周期圆滑中频波：只调「大线条频率」，独立种子流，原大波浪与细齿逐点不变。
    if midWaves > 0 {
        var wr = SplitMix64(seed: seed &+ 9000)
        let f0 = midWaves / 950.0
        var wave = [Double](repeating: 0, count: W)
        for mul in [0.78, 0.94, 1.10, 1.26] {
            let ph = wr.uniform(0, 2 * Double.pi)
            var drift = [Double](repeating: 0, count: W)
            for x in 0..<W { drift[x] = wr.uniform(-1, 1) }
            drift = smooth1d(drift, sigma: 55.0)
            let dn = 0.55 / max(stdOf(drift), 1e-6)
            for x in 0..<W {
                wave[x] += sin(2 * Double.pi * f0 * mul * Double(x) + ph + drift[x] * dn) / 4.0
            }
        }
        // 归一化：除 std 再除 max|·|，乘固定幅度 2.6px（Python mid_wave 同口径）。
        let s = max(stdOf(wave), 1e-6)
        var wmax = 0.0
        for v in wave { wmax = max(wmax, abs(v / s)) }
        let norm = 2.6 / max(wmax, 1e-6)
        for x in 0..<W { y[x] += wave[x] / s * norm }
    }
    let bound = max(6.0, amp * 2.6)
    for x in 0..<W { y[x] = min(max(y[x], -bound), bound) }
    return y
}

// MARK: - 四边拼合（顺时针：上 → 右 → 下 → 左，法向朝选框外）
//
// 齐平裁切（2026-11-08 追加）：选区的某条边与图层可见边缘齐平时，该边不做撕口
// ——直接沿选框边直线全像素裁切（无毛边、无残留），只有不齐平的边呈现撕纸效果。
// 图层可见边界由宿主经 paramsJSON 注入：lb0=左, lb1=上, lb2=右, lb3=下（文档坐标）；
// 未注入（如旋转图层）则四边全部撕口。

private func buildOutline(rect: [Float], params: [String: Any]) -> [Float] {
    guard rect.count >= 8 else { return [] }
    let x0 = Double(rect[0]), y0 = Double(rect[1])
    let x1 = Double(rect[4]), y1 = Double(rect[5])
    guard x1 > x0 + 2, y1 > y0 + 2 else { return [] }

    let profile = (params["profile"] as? String) ?? "rough"
    let seedNum = (params["seed"] as? Double) ?? 20_261_108
    let seed = UInt64(max(0, min(99_999_999, seedNum)))
    let micro = max(0, (params["micro"] as? Double) ?? 0.7)

    // 图层可见边界与齐平判断（容差 2 文档像素：选框拖拽取整在不同 zoom 下与图层
    // 边缘的取整误差 ≤1.5px，齐平边视觉上本就无撕口空间，2px 内判齐平安全）。
    var flushTop = false, flushBottom = false, flushLeft = false, flushRight = false
    if let lx0 = params["lb0"] as? Double, let ly0 = params["lb1"] as? Double,
       let lx1 = params["lb2"] as? Double, let ly1 = params["lb3"] as? Double {
        let tolerance = 2.0
        flushTop = abs(y0 - ly0) <= tolerance
        flushBottom = abs(y1 - ly1) <= tolerance
        flushLeft = abs(x0 - lx0) <= tolerance
        flushRight = abs(x1 - lx1) <= tolerance
    }

    // 每条边独立种子子流（间隔 1000），互不干扰。
    func edgeRng(_ index: Int) -> SplitMix64 { SplitMix64(seed: seed &+ UInt64(index &* 1000)) }

    func profileFor(_ len: Int, rng: inout SplitMix64) -> [Double] {
        if profile == "fine" {
            let amp = max(0, (params["fineAmp"] as? Double) ?? 7)
            let tooth = max(0, (params["fineTooth"] as? Double) ?? 1.3)
            let waveGap = max(60, (params["fineWaveGap"] as? Double) ?? 340)
            let waves = max(0, (params["fineWaves"] as? Double) ?? 14)
            return tearProfileFine(length: len, amp: amp, tooth: tooth, sigma: 1.6,
                                   waveGap: waveGap, midWaves: waves, micro: micro,
                                   seed: seed, rng: &rng)
        } else {
            let amp = max(0, (params["roughAmp"] as? Double) ?? 42)
            let gap = max(40, (params["roughGap"] as? Double) ?? 260)
            let mid = max(0, (params["roughMid"] as? Double) ?? 9)
            let fibers = max(0, (params["roughFibers"] as? Double).map(Int.init) ?? 20)
            return tearProfileRough(length: len, amp: amp, gap: gap, mid: mid,
                                    micro: micro, fibers: fibers, rng: &rng)
        }
    }

    var points: [Float] = []
    // 一条边：p0 → p1，外法向 (nx,ny)，1px 步长采样生成撕口点。
    // straight = 与图层边缘齐平：offsets 全 0，闭合多边形在该边压在选框线上，
    // 撕掉区正好到图层边缘为止 —— 直线全像素裁切。
    func edge(_ p0: (Double, Double), _ p1: (Double, Double), nx: Double, ny: Double,
              seedIndex: Int, straight: Bool) {
        let dx = p1.0 - p0.0, dy = p1.1 - p0.1
        let len = max(2, Int(max(abs(dx), abs(dy)).rounded()))
        var rng = edgeRng(seedIndex)
        let offsets = straight ? [Double](repeating: 0, count: len) : profileFor(len, rng: &rng)
        for i in 0..<len {
            let t = Double(i) / Double(max(len - 1, 1))
            let off = offsets[min(i, offsets.count - 1)]
            points.append(Float(p0.0 + dx * t + nx * off))
            points.append(Float(p0.1 + dy * t + ny * off))
        }
    }

    // 文档坐标 y 向下。上边外=−y、右边外=+x、下边外=+y、左边外=−x。
    edge((x0, y0), (x1, y0), nx: 0, ny: -1, seedIndex: 0, straight: flushTop)
    edge((x1, y0), (x1, y1), nx: 1, ny: 0, seedIndex: 1, straight: flushRight)
    edge((x1, y1), (x0, y1), nx: 0, ny: 1, seedIndex: 2, straight: flushBottom)
    edge((x0, y1), (x0, y0), nx: -1, ny: 0, seedIndex: 3, straight: flushLeft)
    return points
}

// MARK: - C ABI 入口

let entryIdentifier = strdup(pluginIdentifier)!
let entryName = strdup(pluginName)!
let entrySymbol = strdup(pluginSymbol)!
let entryParamsJSON = strdup(pluginParamsJSON)!

@_cdecl("compositor_plugin_main")
public func compositor_plugin_main(_ hostABI: UInt32) -> UnsafeMutableRawPointer {
    let build: @convention(c) (UnsafePointer<Float>, UnsafePointer<CChar>?,
                               UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Int32>) -> Int32 = {
        rect, paramsJSON, outPoints, ioCount in
        let params = parseParams(paramsJSON)
        let points = buildOutline(rect: Array(UnsafeBufferPointer(start: rect, count: 8)), params: params)
        let count = points.count / 2
        guard let outPoints else { ioCount.pointee = Int32(count); return 0 }
        guard Int(ioCount.pointee) >= count else { ioCount.pointee = Int32(count); return 2 }
        points.withUnsafeBufferPointer { buf in
            outPoints.update(from: buf.baseAddress!, count: points.count)
        }
        ioCount.pointee = Int32(count)
        return 0
    }
    let entry = CompositorPluginEntry(
        abiVersion: kHostABI,
        identifier: UnsafePointer(entryIdentifier),
        name: UnsafePointer(entryName),
        symbolName: UnsafePointer(entrySymbol),
        paramsJSON: UnsafePointer(entryParamsJSON),
        buildCutOutline: build)
    let box = UnsafeMutablePointer<CompositorPluginEntry>.allocate(capacity: 1)
    box.initialize(to: entry)
    return UnsafeMutableRawPointer(box)
}
