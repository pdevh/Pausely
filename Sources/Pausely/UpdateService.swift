import Foundation
import AppKit

struct UpdateInfo {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let assetSize: Int64
}

class UpdateService {
    static let shared = UpdateService()
    
    private let gitHubAPIURL = "https://api.github.com/repos/pdevh/Pausely/releases/latest"
    private let assetName = "Pausely-macOS.zip"
    
    /// Posted when an update is available. The object is an UpdateInfo instance.
    static let updateAvailableNotification = Notification.Name("UpdateServiceUpdateAvailable")
    
    private init() {}
    
    /// Returns the current app version from the bundle's Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    
    /// Checks for updates after a 5-second delay. Called on app startup when auto-update is enabled.
    func checkForUpdate() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.performUpdateCheck()
        }
    }
    
    private func performUpdateCheck() {
        guard let url = URL(string: gitHubAPIURL) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Pausely-Updater", forHTTPHeaderField: "User-Agent")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else { return }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                
                // Extract tag_name (e.g., "v1.0.42")
                guard let tagName = json["tag_name"] as? String else { return }
                let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                
                guard self.isNewer(remote: remoteVersion, current: self.currentVersion) else { return }
                
                // Find the correct asset
                guard let assets = json["assets"] as? [[String: Any]] else { return }
                guard let asset = assets.first(where: { ($0["name"] as? String) == self.assetName }) else { return }
                guard let downloadURLString = asset["browser_download_url"] as? String,
                      let downloadURL = URL(string: downloadURLString) else { return }
                
                let assetSize = asset["size"] as? Int64 ?? 0
                let releaseNotes = json["body"] as? String ?? ""
                
                let updateInfo = UpdateInfo(
                    version: remoteVersion,
                    downloadURL: downloadURL,
                    releaseNotes: releaseNotes,
                    assetSize: assetSize
                )
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: UpdateService.updateAvailableNotification,
                        object: updateInfo
                    )
                }
            } catch {
                // Graceful failure — no crash, no UI disruption
            }
        }
        task.resume()
    }
    
    /// Downloads the update ZIP, extracts it, and replaces the app bundle.
    func downloadAndApplyUpdate(_ updateInfo: UpdateInfo, completion: @escaping (Bool) -> Void) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pausely/update", isDirectory: true)
        
        // Clean up previous update attempt
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let zipPath = cacheDir.appendingPathComponent(assetName)
        
        let downloadTask = URLSession.shared.downloadTask(with: updateInfo.downloadURL) { tempURL, response, error in
            guard error == nil,
                  let tempURL = tempURL else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            do {
                // Move downloaded file
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
                
                // Verify file size
                let attrs = try FileManager.default.attributesOfItem(atPath: zipPath.path)
                let downloadedSize = attrs[.size] as? Int64 ?? 0
                if updateInfo.assetSize > 0 && downloadedSize != updateInfo.assetSize {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                // Extract using ditto (preserves macOS metadata and code signatures)
                let extractDir = cacheDir.appendingPathComponent("extracted")
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                
                let dittoProcess = Process()
                dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                dittoProcess.arguments = ["-xk", zipPath.path, extractDir.path]
                try dittoProcess.run()
                dittoProcess.waitUntilExit()
                
                guard dittoProcess.terminationStatus == 0 else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                // Find the .app bundle in the extracted directory
                let extractedContents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
                guard let newAppBundle = extractedContents.first(where: { $0.pathExtension == "app" }) else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                // Get current bundle path
                let currentBundlePath = Bundle.main.bundleURL
                
                // Replace the current app bundle
                let backupPath = currentBundlePath.deletingLastPathComponent()
                    .appendingPathComponent("Pausely_backup.app")
                
                // Remove old backup if exists
                try? FileManager.default.removeItem(at: backupPath)
                
                // Backup current → move new in place
                try FileManager.default.moveItem(at: currentBundlePath, to: backupPath)
                try FileManager.default.moveItem(at: newAppBundle, to: currentBundlePath)
                
                // Remove backup
                try? FileManager.default.removeItem(at: backupPath)
                
                // Relaunch via shell (detached, survives our exit)
                let relaunchScript = "sleep 1 && open '\(currentBundlePath.path)'"
                let shellProcess = Process()
                shellProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
                shellProcess.arguments = ["-c", relaunchScript]
                try shellProcess.run()
                
                DispatchQueue.main.async {
                    completion(true)
                    NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
        downloadTask.resume()
    }
    
    /// Compares two version strings (e.g., "1.0.42" vs "1.0.41").
    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        
        let maxLen = max(remoteParts.count, currentParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
}
