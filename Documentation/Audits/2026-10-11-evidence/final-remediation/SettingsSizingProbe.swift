import AppKit
import SwiftUI
import NotchShotKit
@main struct Probe {
@MainActor static func main() {
 let app=NSApplication.shared
 app.setActivationPolicy(.prohibited)
 let coordinator=AppCoordinator()
 let reduced=CommandLine.arguments.contains("--explicit")
 let start=DispatchTime.now().uptimeNanoseconds
 let window=NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
 let host=NSHostingView(rootView:SettingsView(coordinator:coordinator))
 if reduced {host.sizingOptions=[];window.contentMinSize=NSSize(width:900,height:620)}
 window.contentView=host
 host.layoutSubtreeIfNeeded()
 window.layoutIfNeeded()
 let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
 print("mode=\(reduced ? "explicit" : "standard") layout_ms=\(elapsed) width=\(host.frame.width) height=\(host.frame.height) min_width=\(window.contentMinSize.width) min_height=\(window.contentMinSize.height)")
}
}
