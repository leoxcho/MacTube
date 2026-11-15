import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: apply-mactube-icon.swift <icon.png> <MacTube.app>\n", stderr)
    exit(1)
}

let iconPath = CommandLine.arguments[1]
let appPath = CommandLine.arguments[2]

guard let image = NSImage(contentsOfFile: iconPath) else {
    fputs("Unable to load MacTube icon.\n", stderr)
    exit(1)
}

guard FileManager.default.fileExists(atPath: appPath) else {
    fputs("MacTube application not found.\n", stderr)
    exit(1)
}

guard NSWorkspace.shared.setIcon(
    image,
    forFile: appPath,
    options: []
) else {
    fputs("Unable to apply custom MacTube icon.\n", stderr)
    exit(1)
}

print("Official MacTube icon applied successfully.")
