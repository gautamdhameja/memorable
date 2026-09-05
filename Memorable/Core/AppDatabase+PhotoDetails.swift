import Foundation
import GRDB

extension AppDatabase {
    func recognizedText(photoID: String, isPro: Bool) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT substr(ocrText, 1, ?) FROM indexed_photos
                WHERE id = ? AND (? OR sourceId = ?)
                """, arguments: [OCRTextPolicy.maximumCharacters, photoID, isPro,
                                  PhotoSourceType.photokit.rawValue])
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func photosAround(_ photo: SearchResult, isPro: Bool) throws -> [IndexedPhotoReference] {
        guard let date = photo.creationDate,
              FolderResultAccessPolicy.allows(sourceId: photo.sourceId, isPro: isPro) else { return [] }
        return try dbQueue.read { db in
            // Read metadata only. The date window bounds the scan; LIMIT bounds
            // memory even for bursts/imports. Keep the closest 100, then show time order.
            try Row.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT id, localIdentifier, creationDate, sourceId, filePath, pixelWidth, pixelHeight
                    FROM indexed_photos
                    WHERE creationDate >= ? AND creationDate <= ? AND id != ?
                      AND (? OR sourceId = ?)
                    ORDER BY abs(julianday(creationDate) - julianday(?)), creationDate, id
                    LIMIT 100
                ) ORDER BY creationDate, id
                """, arguments: [date.addingTimeInterval(-3_600), date.addingTimeInterval(3_600),
                                  photo.id, isPro, PhotoSourceType.photokit.rawValue, date])
                .map { row in
                    IndexedPhotoReference(
                        id: row["id"], localIdentifier: row["localIdentifier"],
                        creationDate: row["creationDate"], sourceId: row["sourceId"],
                        filePath: row["filePath"], pixelWidth: row["pixelWidth"], pixelHeight: row["pixelHeight"]
                    )
                }
        }
    }
}
