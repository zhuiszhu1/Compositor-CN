// PluginToolControls.swift — 插件工具的顶部配置区（schema 驱动，无插件专属代码）
//
// 渲染规则：
//   - 标题 = 插件名（L() 查表，词表可汉化，如 "Torn Edge" → 撕边）。
//   - choice 参数（如 Style）→ segmented Picker；它的当前值决定显示哪组参数。
//   - float/int 参数 → 标签（可拖拽改值）+ 滑杆 + 数字框。
//   - dice 参数（如 Seed）→ 数字框 + 骰子按钮换随机种子。

import SwiftUI

struct PluginToolControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        Group {
            if let tool = session.activePluginTool {
                HStack(spacing: 12) {
                    Text(L(tool.name)).font(ToolHeaderStyle.titleFont)
                    ForEach(profileSpecs(tool), id: \.key) { spec in
                        choicePicker(tool, spec)
                    }
                    ForEach(activeGroupParams(tool), id: \.key) { spec in
                        parameterControl(tool, spec)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
                .disabled(session.showsBusy || session.document == nil)
            }
        }
    }

    /// choice 参数当前值决定显示哪组参数；shared 组常显。
    private func activeGroupParams(_ tool: PluginTool) -> [PluginParamSpec] {
        var groups: [String] = []
        for spec in tool.params where spec.type == "choice" {
            let index = Int(PluginManager.shared.value(for: tool, key: spec.key))
            if spec.choices.indices.contains(index) { groups.append(spec.choices[index]) }
        }
        groups.append("shared")
        return tool.params.filter { groups.contains($0.group) && $0.type != "choice" }
    }

    private func profileSpecs(_ tool: PluginTool) -> [PluginParamSpec] {
        tool.params.filter { $0.type == "choice" }
    }

    private func choicePicker(_ tool: PluginTool, _ spec: PluginParamSpec) -> some View {
        Picker(spec.label, selection: binding(tool, spec)) {
            ForEach(spec.choices.indices, id: \.self) { index in
                Text(LocalizedStringKey(spec.choiceLabels[index])).tag(Double(index))
            }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help(L(tool.name) + " — " + L(spec.label))
    }

    @ViewBuilder
    private func parameterControl(_ tool: PluginTool, _ spec: PluginParamSpec) -> some View {
        let isFractional = spec.max <= 10 && spec.type == "float"
        let range = spec.min...max(spec.min, spec.max)
        HStack(spacing: 6) {
            if spec.dice {
                Text(L(spec.label))
                TextField(L(spec.label), value: binding(tool, spec),
                          format: .number.precision(.fractionLength(0)))
                    .frame(width: ToolHeaderStyle.fiveDigits).textFieldStyle(.roundedBorder)
                    .arrowSteps(value: { binding(tool, spec).wrappedValue },
                                change: { binding(tool, spec).wrappedValue = $0 })
                Button {
                    PluginManager.shared.setValue(Double(Int.random(in: 1...99_999_999)), for: tool, key: spec.key)
                } label: {
                    Image(systemName: "dice").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Randomize"))
                .help(L("Roll a new random seed"))
            } else {
                Text(L(spec.label)).scrubbable(sensitivity: spec.max > 100 ? 2 : 0.2,
                                               value: binding(tool, spec), range: range)
                // The slider covers the full declared range; typing or scrubbing also clamps to it.
                AppSlider(value: Binding(get: { binding(tool, spec).wrappedValue },
                                      set: { binding(tool, spec).wrappedValue = $0 }), in: range)
                    .frame(width: 72)
                TextField(L(spec.label), value: binding(tool, spec),
                          format: isFractional ? .number.precision(.fractionLength(0...1)) : .number.precision(.fractionLength(0)))
                    .frame(width: 48).textFieldStyle(.roundedBorder)
                    .arrowSteps(value: { binding(tool, spec).wrappedValue },
                                change: { binding(tool, spec).wrappedValue = min(max($0, spec.min), range.upperBound) })
                    .unitSuffix(L(spec.suffix))
            }
        }
        .help(L(tool.name) + " — " + L(spec.label))
    }

    private func binding(_ tool: PluginTool, _ spec: PluginParamSpec) -> Binding<Double> {
        Binding(
            get: {
                var value = PluginManager.shared.value(for: tool, key: spec.key)
                if value < spec.min { value = spec.min }
                if value > max(spec.min, spec.max) { value = max(spec.min, spec.max) }
                return value
            },
            set: { PluginManager.shared.setValue(min(max($0, spec.min), max(spec.min, spec.max)), for: tool, key: spec.key) })
    }
}
