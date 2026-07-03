import AppKit
import UniformTypeIdentifiers

struct FileImporter {
    enum ImportError: LocalizedError {
        case cancelled
        case invalidType

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "File selection was cancelled."
            case .invalidType:
                return "Please choose a valid audio or video file."
            }
        }
    }

    /// Audio and video containers we can open. `AVAudioFile` reads the audio
    /// track out of video containers, so mp4/mov are valid here too.
    static let supportedContentTypes: [UTType] = [
        .mp3, .mpeg4Audio, .wav, .aiff,
        .mpeg4Movie, .quickTimeMovie,
    ]

    /// File extensions matching `supportedContentTypes`, for validating drops
    /// (where we only have a URL, not a resolved UTType).
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff",
        "mp4", "m4v", "mov",
    ]

    static func openMediaFile(completion: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose an audio or video file"

        panel.begin { response in
            switch response {
            case .OK:
                guard let url = panel.url else {
                    completion(.failure(ImportError.invalidType))
                    return
                }
                completion(.success(url))
            case .cancel:
                completion(.failure(ImportError.cancelled))
            default:
                completion(.failure(ImportError.invalidType))
            }
        }
    }
}
