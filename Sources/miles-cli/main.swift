import MilesCore

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "version", "--version":
    print("miles-cli \(MilesCore.version)")
default:
    print("usage: miles-cli version")
}
