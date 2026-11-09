import Foundation

/// 界面文案统一查表入口：key 为英文原文，返回已翻译文本（词表缺 key 时原样返回英文）。
/// 凡「变量、三元、拼接」形态的显示文本（Text/Button/Toggle/Picker/Menu 的 String 参数、
/// .help/.accessibilityLabel、NSMenuItem/NSMenu 标题、窗口面板标题等）都必须经它包装后交给控件；
/// 这样只换 Localizable.strings 就能更换全部文案，无需重编译。
/// 纯字面量与字面量插值（Text("导出…")、Text("\(x) px")）SwiftUI 会自动查表，无需包装。
@inline(__always)
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
