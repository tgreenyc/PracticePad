import AppKit

struct FileImporter {
    enum ImportError: LocalizedError {
        case cancelled
        case invalidType

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "File selection was cancelled."
            case .invalidType:
                return "Please choose a valid MP3 file."
            }
        }
    }

    static func openMP3File(completion: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose an MP3 file"

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
