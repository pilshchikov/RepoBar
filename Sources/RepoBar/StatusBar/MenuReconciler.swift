import AppKit

extension NSMenu {
    /// Make `self.items` equal `newItems` by inserting/removing only the deltas.
    ///
    /// Items reused across calls (same `NSMenuItem` instance) keep their attached `submenu`,
    /// so an open submenu hanging off a reused item is not closed by AppKit. Callers must
    /// therefore cache the items they hand back here — `NSMenuItem.separator()` returns a
    /// fresh instance each call and will be treated as a different row.
    ///
    /// The algorithm is a two-pointer walk producing only insert/remove operations. Pure
    /// reordering (same set of items, different positions) is handled as remove-then-insert,
    /// which closes a submenu attached to the moved item — but reorders are rare in practice
    /// (the row order is deterministic from settings).
    @MainActor
    func reconcile(with newItems: [NSMenuItem]) {
        let newSet = Set(newItems.map(ObjectIdentifier.init))

        // Remove items not in the new list. Walk in reverse so indices stay valid.
        for index in stride(from: items.count - 1, through: 0, by: -1) {
            let item = items[index]
            if newSet.contains(ObjectIdentifier(item)) == false {
                removeItem(at: index)
            }
        }

        // Walk new items in order, inserting or moving as needed.
        for (targetIndex, newItem) in newItems.enumerated() {
            let currentIndex = index(of: newItem)
            if currentIndex == targetIndex { continue }
            if currentIndex >= 0 {
                removeItem(at: currentIndex)
            }
            insertItem(newItem, at: min(targetIndex, items.count))
        }
    }
}
