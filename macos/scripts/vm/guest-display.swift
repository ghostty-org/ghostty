import CoreGraphics
import Foundation

let display = CGMainDisplayID()

func modes() -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]) ?? []
}

let args = CommandLine.arguments
if args.count < 2 || args[1] == "list" {
    for mode in modes() {
        print("\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight) scale=\(mode.ioDisplayModeID)")
    }
    exit(0)
}

let target = args[1]
guard let mode = modes().first(where: { "\($0.width)x\($0.height)" == target || "\($0.pixelWidth)x\($0.pixelHeight)" == target }) else {
    fputs("mode \(target) not found\n", stderr)
    exit(1)
}
var config: CGDisplayConfigRef?
let begin = CGBeginDisplayConfiguration(&config)
guard begin == .success, let config else { fputs("begin failed \(begin.rawValue)\n", stderr); exit(1) }
let result = CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
guard result == .success else { fputs("configure failed \(result.rawValue)\n", stderr); exit(1) }
let complete = CGCompleteDisplayConfiguration(config, .forSession)
print(complete == .success ? "set \(mode.width)x\(mode.height)" : "complete failed \(complete.rawValue)")
