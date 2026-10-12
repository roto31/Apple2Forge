// List the on-screen windows owned by one process, as "<windowID> <width>x<height>".
// Owner PID and bounds do not need Screen Recording permission (titles and
// pixels do), so this proves a window is showing without capturing it.
// Usage: window_list PID
// Exit codes: 0 at least one window listed, 1 none, 2 bad input.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2, let targetPID = Int(arguments[1]) else {
    FileHandle.standardError.write(Data("Usage: window_list PID\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

var listed = 0
for window in windows {
    guard (window[kCGWindowOwnerPID as String] as? Int) == targetPID,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsInfo)
    else { continue }
    print("\(number) \(Int(bounds.width))x\(Int(bounds.height))")
    listed += 1
}
exit(listed > 0 ? 0 : 1)
