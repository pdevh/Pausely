import AppKit
import Foundation

print("=== 1. NSWorkspace API ===")
if let screen = NSScreen.main {
    if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
        print("NSWorkspace Desktop Image URL: \(url.path)")
    } else {
        print("NSWorkspace: No desktop image URL found for main screen.")
    }
    
    print("\nAll Screens:")
    for (index, s) in NSScreen.screens.enumerated() {
        let url = NSWorkspace.shared.desktopImageURL(for: s)
        print("  Screen \(index) (\(s.frame)): \(url?.path ?? "None")")
    }
}

print("\n=== 2. AppleScript System Events ===")
let appleScriptSource = "tell application \"System Events\" to get picture of current desktop"
var errorDict: NSDictionary?
if let script = NSAppleScript(source: appleScriptSource) {
    let result = script.executeAndReturnError(&errorDict)
    if let error = errorDict {
        print("AppleScript Error: \(error)")
    } else {
        print("AppleScript Result: \(result.stringValue ?? "nil")")
    }
}

print("\n=== 3. Sonoma Wallpaper Index.plist ===")
let plistPath = NSString(string: "~/Library/Application Support/com.apple.wallpaper/Store/Index.plist").expandingTildeInPath

if FileManager.default.fileExists(atPath: plistPath) {
    print("Found Index.plist at: \(plistPath)")
    if let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
       let dict = plist as? [String: Any] {
        
        func dumpDict(_ d: [String: Any], indent: String = "") {
            for (key, val) in d {
                if key == "Configuration" || key == "EncodedOptionValues", let dataVal = val as? Data {
                    print("\(indent)\(key): Data (length: \(dataVal.count))")
                    if let nested = try? PropertyListSerialization.propertyList(from: dataVal, options: [], format: nil) {
                        print("\(indent)  Decoded \(key): \(nested)")
                    }
                } else if let subDict = val as? [String: Any] {
                    print("\(indent)\(key) => {")
                    dumpDict(subDict, indent: indent + "  ")
                    print("\(indent)}")
                } else if let array = val as? [Any] {
                    print("\(indent)\(key) => [")
                    for (i, item) in array.enumerated() {
                        if let itemDict = item as? [String: Any] {
                            print("\(indent)  \(i) => {")
                            dumpDict(itemDict, indent: indent + "    ")
                            print("\(indent)  }")
                        } else {
                            print("\(indent)  \(i) => \(item)")
                        }
                    }
                    print("\(indent)]")
                } else {
                    print("\(indent)\(key): \(val)")
                }
            }
        }
        
        dumpDict(dict)
    } else {
        print("Failed to parse Index.plist as Property List.")
    }
} else {
    print("Index.plist NOT found at: \(plistPath)")
}

print("\n=== 4. Video Wallpaper Handling ===")
// Check pgrep / lsof
let process = Process()
process.launchPath = "/usr/bin/pgrep"
process.arguments = ["WallpaperVideoExtension"]
let pipe = Pipe()
process.standardOutput = pipe
try? process.run()
process.waitUntilExit()
let pgrepData = pipe.fileHandleForReading.readDataToEndOfFile()
if let pidsStr = String(data: pgrepData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !pidsStr.isEmpty {
    print("WallpaperVideoExtension PIDs: \(pidsStr)")
    for pid in pidsStr.components(separatedBy: .whitespacesAndNewlines) {
        print("Open .mov files for PID \(pid):")
        let lsofProcess = Process()
        lsofProcess.launchPath = "/usr/sbin/lsof"
        lsofProcess.arguments = ["-p", pid]
        let lsofPipe = Pipe()
        lsofProcess.standardOutput = lsofPipe
        try? lsofProcess.run()
        lsofProcess.waitUntilExit()
        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        if let lsofStr = String(data: lsofData, encoding: .utf8) {
            let lines = lsofStr.components(separatedBy: .newlines)
            for line in lines where line.contains(".mov") {
                print("  \(line)")
            }
        }
    }
} else {
    print("WallpaperVideoExtension is not running.")
}
