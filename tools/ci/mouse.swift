// Synthesises mouse events for the UI smoke test.
//   swift tools/ci/mouse.swift move <x> <y>
//   swift tools/ci/mouse.swift click <x> <y>
// Coordinates are global, top-left origin (like screencapture).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else {
    print("usage: mouse.swift move|click <x> <y>")
    exit(1)
}
let point = CGPoint(x: x, y: y)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(60_000)
}
post(.mouseMoved)
if args[1] == "click" {
    post(.leftMouseDown)
    post(.leftMouseUp)
}
print("\(args[1]) at \(x), \(y)")
