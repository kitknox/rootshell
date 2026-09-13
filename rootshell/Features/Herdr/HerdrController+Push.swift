import Foundation
import RootshellPushKit

extension HerdrController {
    func resetPushRouteIdentity() {
        pushRouteServerIdentityTask?.cancel()
        pushRouteServerIdentityTask = nil
        pushRouteServerIdentity = nil
    }

    /// Resolve on the gateway's host, never using the device's hostname or an
    /// SSH alias. The command prefix carries the verified local/named session.
    func refreshPushRouteIdentity() {
        guard isActive, !didEnd, pushRouteServerIdentity == nil,
              pushRouteServerIdentityTask == nil else { return }
        let generation = streamGeneration
        pushRouteServerIdentityTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled, self.streamGeneration == generation {
                    self.pushRouteServerIdentityTask = nil
                }
            }
            for attempt in 0..<4 {
                do {
                    let marker = "rootshell-push-" + UUID().uuidString
                    let status = SSHConfig.herdrCommandLine(sessionName: self.sessionName,
                        args: "status --json", localAttachment: self.localControlAttachment)
                    let script = """
                    printf '%s\\n' \(LoginShellCommand.singleQuoted(marker))
                    hostname && id -u && \(status)
                    """
                    let data = try await self.legacyRun(
                        command: LoginShellCommand.runInPOSIXShell(script), method: "push route identity",
                        timeout: .seconds(5), maxResponseBytes: 64 * 1024)
                    try Task.checkCancellation()
                    guard !self.didEnd, self.isActive, self.streamGeneration == generation else { return }
                    let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                    guard let start = lines.firstIndex(of: marker), lines.count > start + 3 else {
                        throw HerdrChannelError.malformed("push route identity missing host")
                    }
                    let host = lines[start + 1]
                    let uid = lines[start + 2]
                    let json = lines.dropFirst(start + 3).joined(separator: "\n")
                    guard let begin = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), begin <= end,
                          let value = try JSONSerialization.jsonObject(with: Data(json[begin...end].utf8)) as? [String: Any],
                          let server = value["server"] as? [String: Any], server["running"] as? Bool == true,
                          let socket = server["socket"] as? String,
                          !uid.isEmpty, uid.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let identity = PushHerdrRoute.serverIdentity(host: host, uid: uid, socket: socket) else {
                        throw HerdrChannelError.malformed("push route identity missing server")
                    }
                    self.pushRouteServerIdentity = identity
                    NotificationCenter.default.post(name: .herdrPaneBindingsChanged, object: nil)
                    return
                } catch {
                    guard !Task.isCancelled, !self.didEnd, self.streamGeneration == generation else { return }
                }
                if attempt < 3 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
    }
}
