/// Keeps UIKit's responder-chain releases paired with the presses it received.
/// Unknown releases still pass through: UIKeyCommand or a previous responder
/// may have received the down event before the terminal saw the release.
struct HardwarePressRouting<Press: Hashable> {
    private var forwardedOnBegin: [Press: Bool] = [:]

    mutating func began(_ presses: Set<Press>, forwarding proposed: Set<Press>) -> Set<Press> {
        for press in presses where forwardedOnBegin[press] == nil {
            forwardedOnBegin[press] = proposed.contains(press)
        }
        // A repeated down cannot hand a terminal-owned press to UIKit midway
        // through its lifetime. Its release belongs to the original owner.
        return proposed.filter { forwardedOnBegin[$0] == true }
    }

    mutating func finished(_ presses: Set<Press>) -> Set<Press> {
        presses.filter { forwardedOnBegin.removeValue(forKey: $0) ?? true }
    }

    mutating func reset() {
        forwardedOnBegin.removeAll()
    }
}
