import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public struct TrayDocumentTransfer: Transferable, Sendable, Codable, Hashable {
    public let editorID: UUID

    public init(editorID: UUID) {
        self.editorID = editorID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .recorteTrayDocument)
    }
}

extension UTType {
    public static let recorteTrayDocument = UTType(exportedAs: "dev.recorte.tray-document", conformingTo: .data)
}
