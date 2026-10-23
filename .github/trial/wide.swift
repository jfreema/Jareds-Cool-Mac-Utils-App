// A regular app in front with Chrome's menus
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let bar = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu(title: "Wide")
bar.addItem(appItem)
for title in ["File", "Edit", "View", "History", "Bookmarks", "Profiles", "Tab", "Window", "Help"] {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = NSMenu(title: title)
    item.submenu?.addItem(withTitle: "Something", action: nil, keyEquivalent: "")
    bar.addItem(item)
}
app.mainMenu = bar
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 420), styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
window.title = "Wide menus"
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
