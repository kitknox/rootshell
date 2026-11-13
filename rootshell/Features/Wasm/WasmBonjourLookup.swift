import Foundation
import dnssd

/// Browses for one Bonjour service type and resolves each instance to a host
/// target, port and addresses, for `rootshell_socket_bonjour_lookup`. Never
/// connects to the service. All state is confined to `queue`.
nonisolated final class WasmBonjourLookup: @unchecked Sendable {
    struct Instance: Sendable {
        let name: String
        var host = ""
        var port: UInt16 = 0
        var addresses: [String] = []
        /// Address lookup failed, so an empty `addresses` is final.
        var addressesFailed = false

        var isComplete: Bool { port != 0 && (!addresses.isEmpty || addressesFailed) }
    }

    private static let queue = DispatchQueue(label: "com.rootshell.wasm.bonjour")
    /// Returns early once every instance has a port and an address and answers stop for this long.
    private static let settle: TimeInterval = 0.5

    /// One dnssd operation's callback context, kept alive until `finish`.
    private final class Op {
        unowned let lookup: WasmBonjourLookup
        let name: String
        init(lookup: WasmBonjourLookup, name: String) {
            self.lookup = lookup
            self.name = name
        }
    }

    private let completion: @Sendable (Int32, [Instance]) -> Void
    private var refs: [DNSServiceRef] = []
    private var ops: [Op] = []
    private var instances: [String: Instance] = [:]
    private var order: [String] = []
    private var settleWork: DispatchWorkItem?
    private var finished = false

    /// Completes with a WASI errno and the instances that resolved, in
    /// discovery order. ETIMEDOUT when none resolved before `timeout`.
    static func start(type: String, timeout: TimeInterval,
                      completion: @escaping @Sendable (Int32, [Instance]) -> Void) {
        let lookup = WasmBonjourLookup(completion: completion)
        queue.async {
            lookup.browse(type: type)
            queue.asyncAfter(deadline: .now() + timeout) { lookup.finish(0) }
        }
    }

    private init(completion: @escaping @Sendable (Int32, [Instance]) -> Void) {
        self.completion = completion
    }

    /// One line per instance: name, host, port, then comma-separated addresses, tab-separated.
    static func format(_ instances: [Instance]) -> String {
        instances.map { item in
            let name = item.name.map { $0 == "\t" || $0.isNewline ? " " : $0 }
            return "\(String(name))\t\(item.host)\t\(item.port)\t\(item.addresses.joined(separator: ","))\n"
        }.joined()
    }

    // MARK: - dnssd

    private func browse(type: String) {
        let op = Op(lookup: self, name: "")
        var ref: DNSServiceRef?
        let err = DNSServiceBrowse(
            &ref, 0, 0, type, "local.",
            { _, flags, interface, error, name, regtype, domain, context in
                guard let context else { return }
                let op = Unmanaged<Op>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { return op.lookup.fail(error) }
                guard flags & kDNSServiceFlagsAdd != 0, let name, let regtype, let domain else { return }
                op.lookup.resolve(name: String(cString: name), type: String(cString: regtype),
                                  domain: String(cString: domain), interface: interface)
            },
            Unmanaged.passUnretained(op).toOpaque())
        track(ref, op: op, error: err)
    }

    private func resolve(name: String, type: String, domain: String, interface: UInt32) {
        // Instances seen on several interfaces resolve once.
        guard !finished, instances[name] == nil else { return }
        instances[name] = Instance(name: name)
        order.append(name)
        let op = Op(lookup: self, name: name)
        var ref: DNSServiceRef?
        let err = DNSServiceResolve(
            &ref, 0, interface, name, type, domain,
            { _, _, interface, error, _, host, port, _, _, context in
                guard let context else { return }
                let op = Unmanaged<Op>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError, let host else { return }
                op.lookup.resolved(op.name, host: String(cString: host),
                                   port: UInt16(bigEndian: port), interface: interface)
            },
            Unmanaged.passUnretained(op).toOpaque())
        track(ref, op: op, error: err)
    }

    private func resolved(_ name: String, host: String, port: UInt16, interface: UInt32) {
        guard !finished, var item = instances[name], item.port == 0 else { return }
        item.host = host
        item.port = port
        instances[name] = item
        scheduleSettle()

        let op = Op(lookup: self, name: name)
        var ref: DNSServiceRef?
        let err = DNSServiceGetAddrInfo(
            &ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host,
            { _, flags, _, error, _, address, _, context in
                guard let context else { return }
                let op = Unmanaged<Op>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { return op.lookup.addressesFailed(op.name) }
                guard flags & kDNSServiceFlagsAdd != 0, let address,
                      let text = WasmBonjourLookup.numericHost(address) else { return }
                op.lookup.addAddress(text, to: op.name)
            },
            Unmanaged.passUnretained(op).toOpaque())
        track(ref, op: op, error: err)
    }

    private func addressesFailed(_ name: String) {
        guard !finished, var item = instances[name] else { return }
        item.addressesFailed = true
        instances[name] = item
        scheduleSettle()
    }

    private func addAddress(_ address: String, to name: String) {
        guard !finished, var item = instances[name], !item.addresses.contains(address) else { return }
        item.addresses.append(address)
        instances[name] = item
        scheduleSettle()
    }

    private func track(_ ref: DNSServiceRef?, op: Op, error: DNSServiceErrorType) {
        guard error == kDNSServiceErr_NoError, let ref else {
            guard let item = instances[op.name] else { return fail(error) }
            if item.port != 0 { return addressesFailed(op.name) }
            // A resolve that can't start drops just that instance.
            instances[op.name] = nil
            order.removeAll { $0 == op.name }
            return
        }
        refs.append(ref)
        ops.append(op)
        DNSServiceSetDispatchQueue(ref, Self.queue)
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [self] in
            if instances.values.allSatisfy(\.isComplete) { finish(0) }
        }
        settleWork = work
        Self.queue.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Fails only when nothing has resolved; a late error keeps what came in.
    private func fail(_ error: DNSServiceErrorType) {
        switch Int(error) {
        case kDNSServiceErr_NoAuth, kDNSServiceErr_PolicyDenied:
            // The type is missing from NSBonjourServices, or Local Network is off.
            finish(Errno.EACCES)
        case kDNSServiceErr_BadParam:
            finish(Errno.EINVAL)
        default:
            finish(Errno.EIO)
        }
    }

    private func finish(_ error: Int32) {
        guard !finished else { return }
        finished = true
        settleWork?.cancel()
        for ref in refs { DNSServiceRefDeallocate(ref) }
        refs.removeAll()
        ops.removeAll()
        let found = order.compactMap { instances[$0] }.filter { $0.port != 0 }
        if !found.isEmpty {
            completion(0, found)
        } else {
            completion(error == 0 ? Errno.ETIMEDOUT : error, [])
        }
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                             nil, 0, NI_NUMERICHOST)
        return rc == 0 ? WasmUDPSocket.cString(host) : nil
    }
}
