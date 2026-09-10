import Foundation

nonisolated enum HerdrAttachCommand {
    /// Vanilla attach ORs the child's capture requests with ui.mouse_capture.
    /// Turn off that client preference so its ANSI modes reflect the child.
    /// Keep this private config alive for reloads and remove it on detach.
    /// The running server retains its own configuration.
    static func make(sessionName: String?, terminalId: String) -> String {
        let session = sessionName.map { " --session " + LoginShellCommand.singleQuoted($0) } ?? ""
        let script = LoginShellCommand.pathPrefix
            + "_rhc=$(mktemp /tmp/rs-herdr.XXXXXX) || exit; "
            + "trap 'rm -f \"$_rhc\"' 0; trap 'exit 129' 1; "
            + "printf '[ui]\\nmouse_capture=false\\n' >\"$_rhc\" || exit; "
            + "HERDR_CONFIG_PATH=$_rhc herdr\(session) terminal attach "
            + LoginShellCommand.singleQuoted(terminalId) + " --takeover"
        return LoginShellCommand.runInPOSIXShell(script)
    }
}
