import Foundation
import Testing
@testable import Conterm

/// A light/dark pair comments out explicit colors and theme includes so
/// they can't shadow `theme = light:…,dark:…`, and must be able to undo it.
@MainActor
struct UserConfigStoreTests {
    let themes = "/Users/u/.config/conterm/themes"

    @Test func disablesColorsAndThemeIncludesOnly() {
        let lines = [
            "font-size = 13",
            "background = #000000",
            "palette = 1=#ff0000",
            "bold-color = #ffffff",
            "config-file = /Users/u/.config/conterm/themes/Alexis Light",
            "config-file = ?\"/Users/u/.config/conterm/themes/x\"",
            "config-file = /Users/u/dev/themes/other",
            "config-file = /Users/u/.config/ghostty/config",
            "# background = #111111",
            "background-opacity = 1",
        ]
        let m = UserConfigStore.disabledMarker
        #expect(UserConfigStore.disablingColorLines(lines, themesDir: themes) == [
            "font-size = 13",
            m + "background = #000000",
            m + "palette = 1=#ff0000",
            m + "bold-color = #ffffff",
            m + "config-file = /Users/u/.config/conterm/themes/Alexis Light",
            m + "config-file = ?\"/Users/u/.config/conterm/themes/x\"",
            "config-file = /Users/u/dev/themes/other",
            "config-file = /Users/u/.config/ghostty/config",
            "# background = #111111",
            "background-opacity = 1",
        ])
    }

    @Test func restoreUndoesDisable() {
        let lines = ["background = #000000", "font-size = 13",
                     "config-file = /Users/u/.config/conterm/themes/a"]
        let disabled = UserConfigStore.disablingColorLines(lines, themesDir: themes)
        #expect(UserConfigStore.restoringColorLines(disabled) == lines)
        // Lines the user commented themselves stay commented.
        #expect(UserConfigStore.restoringColorLines(["# background = #1"]) == ["# background = #1"])
    }
}
