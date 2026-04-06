import Foundation

class SmartAlbumStore {
    private static var db: DatabaseProtocol { AppDatabase.shared }

    static func load() -> [SmartAlbum] {
        do {
            return try db.loadSmartAlbums()
        } catch {
            logger.error("Failed to load smart albums: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ albums: [SmartAlbum]) {
        for album in albums {
            do {
                try db.saveSmartAlbum(album)
            } catch {
                logger.error("Failed to save smart album '\(album.name)': \(error.localizedDescription)")
            }
        }
    }

    static func add(name: String, query: String) {
        let album = SmartAlbum(
            id: UUID().uuidString,
            name: name,
            query: query,
            createdAt: Date()
        )
        do {
            try db.saveSmartAlbum(album)
        } catch {
            logger.error("Failed to add smart album '\(name)': \(error.localizedDescription)")
        }
    }

    static func delete(id: String) {
        do {
            try db.deleteSmartAlbum(id: id)
        } catch {
            logger.error("Failed to delete smart album: \(error.localizedDescription)")
        }
    }
}
