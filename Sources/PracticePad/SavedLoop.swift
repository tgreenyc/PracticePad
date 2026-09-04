import Foundation

/// A named A–B region the user has saved for a track, so they can recall and
/// jump between passages (e.g. "Verse", "Chorus", "Solo") while practicing.
///
/// Times are in seconds from the start of the track. Persisted per file by
/// `AudioPlayer`; recalling one loads its bounds into the active A–B loop.
struct SavedLoop: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var start: TimeInterval
    var end: TimeInterval

    init(id: UUID = UUID(), name: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
    }
}
