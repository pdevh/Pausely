import Cocoa

struct SoundManager {
    /// Play a pleasant sound to signal the beginning of a break
    static func playStartSound() {
        // macOS built-in "Glass" or "Hero" sounds are gentle and professional
        if let sound = NSSound(named: "Glass") ?? NSSound(named: "Hero") {
            sound.play()
        }
    }
    
    /// Play a clean sound to signal the end of a break
    static func playEndSound() {
        // macOS built-in "Tink" or "Ping" sounds indicate task completion
        if let sound = NSSound(named: "Tink") ?? NSSound(named: "Purr") {
            sound.play()
        }
    }
}
