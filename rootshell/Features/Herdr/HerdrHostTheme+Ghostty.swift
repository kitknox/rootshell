// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation
import GhosttyKit

extension HerdrHostTheme {
    init?(config: ghostty_config_t, themeName: String) {
        func get<T>(_ key: String, _ value: inout T) -> Bool {
            withUnsafeMutablePointer(to: &value) {
                ghostty_config_get(config, $0, key, UInt(key.utf8.count))
            }
        }
        var foreground = ghostty_config_color_s()
        var background = ghostty_config_color_s()
        var palette = ghostty_config_palette_s()
        guard get("foreground", &foreground),
              get("background", &background),
              get("palette", &palette) else { return nil }
        self.foreground = RGB(r: foreground.r, g: foreground.g, b: foreground.b)
        self.background = RGB(r: background.r, g: background.g, b: background.b)
        self.palette = withUnsafeBytes(of: palette.colors) { bytes in
            bytes.bindMemory(to: ghostty_config_color_s.self).map { RGB(r: $0.r, g: $0.g, b: $0.b) }
        }
        var generate = false, harmonious = false
        if get("palette-generate", &generate), generate {
            _ = get("palette-harmonious", &harmonious)
            let source: String?
            if let custom = CustomThemeManager.shared.customThemes.first(where: { $0.name == themeName }) {
                source = custom.toGhosttyFileContent()
            } else if let file = ThemeManager.shared.themeInfo(for: themeName)?.filePath {
                source = try? String(contentsOf: file, encoding: .utf8)
            } else { source = nil }
            if let source {
                self.palette = HerdrHostPalette.generate(self, explicit: HerdrHostPalette.explicitIndices(in: source),
                                                         harmonious: harmonious)
            }
        }
    }
}

extension HerdrController {
    /// One upstream client owns one host theme. Hidden tabs keep their local
    /// configs; only the selected tab supplies upstream's shared defaults.
    func synchronizeEndpointTheme() {
        guard mode == .legacy, !didEnd, let endpoint, endpoint.boot != nil else { return }
        let selected = tabs.values.first { $0.id == tabsModel.selectedTabID }
        let active = selected != nil && !legacySuspended && !Ghostty.isAppBackgroundedAtomic
        let view = selected?.focusedTerminal ?? selected?.splitTree.terminalLeaves.first
        if active, let theme = view?.herdrHostTheme { endpoint.setHostTheme(theme) }
        endpoint.setHostFocus(active && view?.herdrHostWindowFocused == true)
    }
}
