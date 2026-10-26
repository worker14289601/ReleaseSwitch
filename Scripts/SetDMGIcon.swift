import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[2]),
      NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[1], options: []) else {
    fputs("Could not set the disk image icon.\n", stderr)
    exit(1)
}
print("DMG application icon set.")
