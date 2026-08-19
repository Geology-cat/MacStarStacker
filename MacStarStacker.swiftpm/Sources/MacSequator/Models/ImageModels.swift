import Foundation

enum ImageType: String, CaseIterable, Identifiable {
    case base = "Base"
    case light = "Light"
    case dark = "Dark"
    case flat = "Flat"
    case bias = "Bias"
    
    var id: Self { self }
}

public enum MaskBrush: String, CaseIterable, Identifiable {
    case sky    = "空 (青)"
    case ground = "地上 (緑)"
    case erase  = "消しゴム"
    public var id: Self { self }
}

struct ImageFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var metadata: RawMetadataInfo? = nil
    
    var name: String {
        url.lastPathComponent
    }
    
    var subtitle: String {
        if let meta = metadata, !meta.displayName.isEmpty {
            return meta.displayName
        }
        return url.pathExtension.uppercased()
    }
    
    init(url: URL, metadata: RawMetadataInfo? = nil) {
        self.id = UUID()
        self.url = url
        self.metadata = metadata
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url
    }
}
