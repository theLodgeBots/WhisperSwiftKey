import Foundation

struct Transcription: Identifiable, Codable, Equatable {
    let id: UUID
    let originalText: String
    let timestamp: Date
    let durationSeconds: Double
    let language: String?
    let wordCount: Int

    init(
        id: UUID = UUID(),
        originalText: String,
        timestamp: Date = Date(),
        durationSeconds: Double,
        language: String?
    ) {
        self.id = id
        self.originalText = originalText
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.language = language
        self.wordCount = originalText
            .split(whereSeparator: \.isWhitespace)
            .count
    }
}
