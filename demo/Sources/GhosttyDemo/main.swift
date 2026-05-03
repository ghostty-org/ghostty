import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 显式设置激活策略，确保即使不在 .app bundle 中也能接收键盘事件
app.setActivationPolicy(.regular)
app.run()
