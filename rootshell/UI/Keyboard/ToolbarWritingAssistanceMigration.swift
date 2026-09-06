/// Kept independent of UIKit so layout migration can be checked without an app
/// host. Existing placement or an explicit hidden choice always wins.
nonisolated enum ToolbarWritingAssistanceMigration {
    static func insert<Slot: Equatable>(mainRow: inout [Slot], drawerRows: inout [[Slot]],
                                       compose: Slot, assistance: Slot, hidden: Bool, defaultIndex: Int) {
        guard !hidden, !mainRow.contains(assistance),
              !drawerRows.contains(where: { $0.contains(assistance) }) else { return }
        if let index = mainRow.firstIndex(of: compose) {
            mainRow.insert(assistance, at: index + 1)
        } else if let row = drawerRows.firstIndex(where: { $0.contains(compose) }),
                  let index = drawerRows[row].firstIndex(of: compose) {
            drawerRows[row].insert(assistance, at: index + 1)
        } else {
            mainRow.insert(assistance, at: max(0, min(defaultIndex, mainRow.count)))
        }
    }
}
