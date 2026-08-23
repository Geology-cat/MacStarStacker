import Foundation
import AppKit

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

public struct ImageFile: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public var metadata: RawMetadataInfo? = nil
    
    public var name: String {
        url.lastPathComponent
    }
    
    public var subtitle: String {
        if let meta = metadata, !meta.displayName.isEmpty {
            return meta.displayName
        }
        return url.pathExtension.uppercased()
    }
    
    public init(url: URL, metadata: RawMetadataInfo? = nil) {
        self.id = UUID()
        self.url = url
        self.metadata = metadata
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
    }

    public static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url
    }
}

/// 検出された光跡アイテム（UIレビュー用）
public struct DetectedTrailItem: Identifiable, Hashable {
    public let id = UUID()
    public var frameIndex: Int
    public var file: ImageFile
    public var originalImage: NSImage?
    public var maskImage: NSImage?
    public var highlightedImage: NSImage?
    public var repairedImage: NSImage?
    public var detectedType: String
    public var confidenceScore: Double
    public var isLikelyMeteor: Bool
    public var isMarkedForRemoval: Bool

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(file.id)
    }

    public static func == (lhs: DetectedTrailItem, rhs: DetectedTrailItem) -> Bool {
        lhs.id == rhs.id
    }
}
