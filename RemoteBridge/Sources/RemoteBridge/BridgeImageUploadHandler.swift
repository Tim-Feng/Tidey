import Foundation

protocol BridgeImageUploadDestinationResolving {
    func uploadDirectory() throws -> URL
}

protocol BridgeImageUploadFilenameGenerating {
    func nextFilename() -> String
}

struct BridgeImageUploadHandler {
    private let destinationResolver: BridgeImageUploadDestinationResolving
    private let filenameGenerator: BridgeImageUploadFilenameGenerating
    private let fileManager: FileManager

    init(destinationResolver: BridgeImageUploadDestinationResolving,
         filenameGenerator: BridgeImageUploadFilenameGenerating,
         fileManager: FileManager = .default) {
        self.destinationResolver = destinationResolver
        self.filenameGenerator = filenameGenerator
        self.fileManager = fileManager
    }

    func handle(_ request: BridgeRequest) throws -> BridgeResponse? {
        guard request.action == "image_upload" else {
            return nil
        }
        throw BridgeInternalError.invalidRequest("image_upload is not implemented")
    }
}
