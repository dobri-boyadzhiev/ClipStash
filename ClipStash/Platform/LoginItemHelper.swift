import LaunchAtLogin
import SwiftUI

/// Wrapper around LaunchAtLogin for simple start-at-login toggle.
/// Uses the modern SMAppService approach (macOS 13+).
struct LaunchAtLoginToggle: View {
    var body: some View {
        LaunchAtLogin.Toggle("Start at Login")
    }
}
