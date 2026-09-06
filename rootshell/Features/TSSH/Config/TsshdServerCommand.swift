//
//  TsshdServerCommand.swift
//  rootshell
//

/// Shared tsshd bootstrap for terminal sessions and VPN tunnels.
nonisolated enum TsshdServerCommand {
    static func command(
        serverPath: String?,
        portMin: Int,
        portMax: Int,
        mtu: Int?,
        quic: Bool,
        attachable: Bool,
        debug: Bool
    ) -> String {
        let binary = serverPath ?? "tsshd"
        var args = attachable ? " --attachable" : ""
        args += " --port \(portMin)-\(portMax)"
        if let mtu { args += " --mtu \(mtu)" }
        args += quic ? " --quic" : " --kcp"
        if debug { args += " --debug" }

        // Custom paths retain shell expansion and skip PATH discovery.
        guard serverPath == nil else { return binary + args }
        return LoginShellCommand.runInPOSIXShell(LoginShellCommand.pathPrefix + "exec " + binary + args)
    }
}
