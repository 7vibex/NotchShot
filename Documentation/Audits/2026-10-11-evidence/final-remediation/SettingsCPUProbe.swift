import AppKit
import SwiftUI
import NotchShotKit
@main struct Probe {
@MainActor static func main() {
 let app=NSApplication.shared
 app.setActivationPolicy(.prohibited)
 let coordinator=AppCoordinator()
 let reduced=CommandLine.arguments.contains("--explicit")
 var cpuStart=timespec()
 clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuStart)
 let start=DispatchTime.now().uptimeNanoseconds
 let window=NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
 let host=NSHostingView(rootView:SettingsView(coordinator:coordinator))
 if reduced {
  let container=NSView(frame:NSRect(x:0,y:0,width:980,height:700))
  host.sizingOptions=[]
  host.frame=container.bounds
  host.autoresizingMask=[.width,.height]
  container.addSubview(host)
  window.contentView=container
  window.contentMinSize=NSSize(width:900,height:620)
 } else {window.contentView=host}
 host.layoutSubtreeIfNeeded()
 window.layoutIfNeeded()
 let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
 var cpuEnd=timespec()
 clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuEnd)
 let cpu=Double(cpuEnd.tv_sec-cpuStart.tv_sec)*1000+Double(cpuEnd.tv_nsec-cpuStart.tv_nsec)/1_000_000
 print("mode=\(reduced ? "container" : "standard") layout_ms=\(elapsed) cpu_ms=\(cpu) width=\(host.frame.width) height=\(host.frame.height) min_width=\(window.contentMinSize.width) min_height=\(window.contentMinSize.height)")
}
}
