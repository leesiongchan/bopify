import Foundation

func playbackTime(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1000)
    return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
}
