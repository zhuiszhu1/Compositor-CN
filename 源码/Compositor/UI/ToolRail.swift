import SwiftUI

/// How the tool rail lays out its tools: one column as it always has, or two for a rail about half as tall when one
/// doesn't fit.
enum ToolRailLayout {
    static let buttonSize: CGFloat = 36
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 10

    /// 56 pt in one column; 92 in two (two buttons, the gap between them and 6 pt margins each side).
    static func width(columns: Int) -> CGFloat {
        columns >= 2 ? buttonSize * 2 + columnSpacing + 12 : 56
    }

    /// The tools in rows of `columns`, in the rail's order read left to right.
    static func rows(_ tools: [NavigationTool], columns: Int) -> [[NavigationTool]] {
        let count = min(2, max(1, columns))
        return stride(from: 0, to: tools.count, by: count).map { Array(tools[$0..<min($0 + count, tools.count)]) }
    }
}

/// The tools down the left of the window, with the color swatches under them: in one column while it fits the
/// window's height, otherwise in two, which scroll if the window is shorter still.
struct ToolRail: View {
    @Bindable var session: EditorSession

    var body: some View {
        ViewThatFits(in: .vertical) {
            ToolRailStack(session: session, columns: 1)
            // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
            IndicatorlessScrollView { ToolRailStack(session: session, columns: 2) }
                .frame(width: ToolRailLayout.width(columns: 2))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The rail's contents: the tools in rows, and the color swatches.
struct ToolRailStack: View {
    @Bindable var session: EditorSession
    let columns: Int

    private var tools: [NavigationTool] { NavigationTool.allCases.filter { $0 != .idle && $0 != .plugin } }

    var body: some View {
        let width = ToolRailLayout.width(columns: columns)
        let twoColumns = columns >= 2
        VStack(spacing: ToolRailLayout.rowSpacing) {
            ForEach(Array(ToolRailLayout.rows(tools, columns: columns).enumerated()), id: \.offset) { _, row in
                HStack(spacing: ToolRailLayout.columnSpacing) {
                    ForEach(row, id: \.self) { toolButton($0) }
                }
                // A lone last tool stays in the left column.
                .frame(width: twoColumns ? ToolRailLayout.buttonSize * 2 + ToolRailLayout.columnSpacing : ToolRailLayout.buttonSize,
                       alignment: .leading)
            }
            // Loaded canvas-tool plugins (Torn Edge and friends) sit under the built-ins;
            // other kinds (such as export plugins) surface elsewhere, not on the rail.
            ForEach(PluginManager.shared.tools.filter(\.isCanvasTool)) { tool in
                pluginButton(tool)
            }
            ColorPaletteControls(session: session)
            // The rail's bottom: import a .compositorplugin from disk, and it loads on the spot.
            ImportPluginButton(session: session)
        }
        .padding(.top, 16).padding(.bottom, 12)
        .frame(width: width)
    }

    private func toolButton(_ tool: NavigationTool) -> some View {
        Button { session.selectTool(tool) } label: {
            Group {
                // SF Symbol "textformat" 在简中系统会被本地化成「格式」两个字。改用词表驱动的
                // 文字图标，让文字工具显示为「文本」，且换语言包即可改，不必重编译。
                if tool == .type { Text(L("text")).font(.system(size: 13, weight: .medium)) }
                else if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
                else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
                else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
                else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
                // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
                else {
                    Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool))
                        .font(.system(size: 17))
                        // The hand turned so its thumb is on the left, as a left hand grabbing the canvas.
                        .scaleEffect(x: tool == .hand ? -1 : 1, y: 1)
                }
            }
            .frame(width: ToolRailLayout.buttonSize, height: ToolRailLayout.buttonSize)
            .background(session.tool == tool ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(session.tool == tool ? Color.white.opacity(0.14) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L(tool.label)).accessibilityLabel(L(tool.label))
        .foregroundStyle(.primary)
        .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
    }

    /// A loaded plugin's tool button: the plugin picks its own symbol; selecting it points the
    /// shared `.plugin` tool state at this plugin.
    private func pluginButton(_ pluginTool: PluginTool) -> some View {
        let selected = session.tool == .plugin && session.activePluginToolID == pluginTool.id
        return Button { session.activatePluginTool(pluginTool) } label: {
            Image(systemName: pluginTool.symbolName)
                .font(.system(size: 17))
                .frame(width: ToolRailLayout.buttonSize, height: ToolRailLayout.buttonSize)
                .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.white.opacity(0.14) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(pluginTool.name) + " — " + L("box an area, then press Delete"))
        .accessibilityLabel(L(pluginTool.name))
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The rail's bottom button: pick a `.compositorplugin` bundle from disk and it's copied into the
/// plugins folder and loaded on the spot — canvas tools join the rail above, export plugins join
/// the File menu. A same-identifier import is an update: the new file takes over on next launch.
private struct ImportPluginButton: View {
    let session: EditorSession
    @State private var feedback: Feedback?

    private struct Feedback: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Button { choosePlugin() } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 17))
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(x: 4, y: 2)
            }
            .frame(width: ToolRailLayout.buttonSize, height: ToolRailLayout.buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Import Plugin…"))
        .accessibilityLabel(L("Import Plugin…"))
        .foregroundStyle(.primary)
        .alert(feedback?.title ?? "", isPresented: feedbackBinding) {
            Button(L("OK")) { feedback = nil }
        } message: {
            Text(feedback?.message ?? "")
        }
    }

    private var feedbackBinding: Binding<Bool> {
        Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })
    }

    /// The panel accepts both bundle shapes: a package-declared bundle as a file, and a plain
    /// folder with no Info.plist as a directory. `importPlugin` validates the extension.
    private func choosePlugin() {
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.treatsFilePackagesAsDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = L("Import Plugin…")
            panel.message = L("Choose a plugin bundle (.compositorplugin) to import.")
            panel.prompt = L("Import")
            guard await panel.begin() == .OK, let url = panel.url else { return }
            switch PluginManager.shared.importPlugin(from: url) {
            case .added(let tool):
                // The rail's ForEach reads the @Observable tools array, so the button shows up at once.
                session.activatePluginTool(tool)
            case .updated:
                feedback = Feedback(title: L("Plugin Updated"),
                                    message: L("A plugin with the same identifier is already loaded. The new version will load the next time you start Compositor."))
            case .failed(let reason):
                feedback = Feedback(title: L("Couldn’t Import Plugin"), message: reason)
            }
        }
    }
}
