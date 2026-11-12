import AppKit

// Orol: a Dynamic Island for the Mac notch, with Claude inside.
//
//   Orol                 run the island
//   Orol --shots <dir>   render every state to PNG files (no window, nothing touched)

let app = NSApplication.shared
let arguments = CommandLine.arguments

if let i = arguments.firstIndex(of: "--shots"), i + 1 < arguments.count {
    app.setActivationPolicy(.prohibited)
    Shots.run(directory: arguments[i + 1])
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
