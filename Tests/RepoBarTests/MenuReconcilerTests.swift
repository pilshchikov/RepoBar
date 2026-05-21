import AppKit
@testable import RepoBar
import Testing

@MainActor
struct MenuReconcilerTests {
    @Test
    func `noop when items already match`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, b, c])
        let snapshot = menu.items

        menu.reconcile(with: [a, b, c])

        #expect(menu.items.map(ObjectIdentifier.init) == snapshot.map(ObjectIdentifier.init))
    }

    @Test
    func `inserts new item at start`() {
        let menu = NSMenu()
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")
        menu.reconcile(with: [b, c])
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")

        menu.reconcile(with: [a, b, c])

        #expect(menu.items.map(\.title) == ["a", "b", "c"])
        #expect(ObjectIdentifier(menu.items[1]) == ObjectIdentifier(b))
        #expect(ObjectIdentifier(menu.items[2]) == ObjectIdentifier(c))
    }

    @Test
    func `inserts new item at end`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, b])
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")

        menu.reconcile(with: [a, b, c])

        #expect(menu.items.map(\.title) == ["a", "b", "c"])
        #expect(ObjectIdentifier(menu.items[2]) == ObjectIdentifier(c))
    }

    @Test
    func `inserts new item in middle`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, c])
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")

        menu.reconcile(with: [a, b, c])

        #expect(menu.items.map(\.title) == ["a", "b", "c"])
    }

    @Test
    func `removes item from start`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, b, c])

        menu.reconcile(with: [b, c])

        #expect(menu.items.map(\.title) == ["b", "c"])
    }

    @Test
    func `removes item from middle`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, b, c])

        menu.reconcile(with: [a, c])

        #expect(menu.items.map(\.title) == ["a", "c"])
    }

    @Test
    func `removes item from end`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, b, c])

        menu.reconcile(with: [a, b])

        #expect(menu.items.map(\.title) == ["a", "b"])
    }

    @Test
    func `clears menu when new list is empty`() {
        let menu = NSMenu()
        menu.reconcile(with: [
            NSMenuItem(title: "a", action: nil, keyEquivalent: ""),
            NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        ])

        menu.reconcile(with: [])

        #expect(menu.items.isEmpty)
    }

    @Test
    func `submenu attached to reused item is preserved`() {
        let menu = NSMenu()
        let parent = NSMenuItem(title: "parent", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "child")
        submenu.addItem(NSMenuItem(title: "grandchild", action: nil, keyEquivalent: ""))
        parent.submenu = submenu
        let sibling = NSMenuItem(title: "sibling", action: nil, keyEquivalent: "")

        menu.reconcile(with: [parent, sibling])
        // Same parent instance, sibling removed and a new one added; parent.submenu must survive.
        let newSibling = NSMenuItem(title: "newSibling", action: nil, keyEquivalent: "")
        menu.reconcile(with: [parent, newSibling])

        #expect(parent.submenu === submenu)
        #expect(parent.submenu?.items.first?.title == "grandchild")
    }

    @Test
    func `replaces all items when none are reused`() {
        let menu = NSMenu()
        menu.reconcile(with: [
            NSMenuItem(title: "old1", action: nil, keyEquivalent: ""),
            NSMenuItem(title: "old2", action: nil, keyEquivalent: "")
        ])
        let new1 = NSMenuItem(title: "new1", action: nil, keyEquivalent: "")
        let new2 = NSMenuItem(title: "new2", action: nil, keyEquivalent: "")

        menu.reconcile(with: [new1, new2])

        #expect(menu.items.map(\.title) == ["new1", "new2"])
        #expect(ObjectIdentifier(menu.items[0]) == ObjectIdentifier(new1))
    }

    @Test
    func `swaps items mid-list, keeping flanking instances stable`() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        let d = NSMenuItem(title: "d", action: nil, keyEquivalent: "")
        menu.reconcile(with: [a, b, d])
        let c = NSMenuItem(title: "c", action: nil, keyEquivalent: "")

        // Replace b with c; a and d should be the same instances.
        menu.reconcile(with: [a, c, d])

        #expect(menu.items.map(\.title) == ["a", "c", "d"])
        #expect(ObjectIdentifier(menu.items[0]) == ObjectIdentifier(a))
        #expect(ObjectIdentifier(menu.items[2]) == ObjectIdentifier(d))
    }
}
