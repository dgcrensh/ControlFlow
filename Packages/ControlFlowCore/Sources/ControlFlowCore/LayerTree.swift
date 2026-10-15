import Foundation

/// What the layers panel shows: the layers, each with its groups, then the reference
/// images. Layers are listed front to back (the reverse of draw order), like most
/// drawing apps.
public struct LayerTree: Hashable, Sendable {
    public struct LayerItem: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var shapeCount: Int
        public var isHidden: Bool
        public var isLocked: Bool
        /// True when some shapes in the layer are hidden or locked on their own.
        public var hasHiddenOrLockedShapes: Bool
        /// The layer's groups of shapes, front to back.
        public var groups: [GroupLayer] = []
    }

    /// A group of shapes inside one layer.
    public struct GroupLayer: Hashable, Sendable, Identifiable {
        public var id: Int
        /// The layer the group is in.
        public var layer: Int
        public var name: String
        public var shapeCount: Int
        /// True when every shape of the group is hidden, or locked.
        public var isHidden: Bool
        public var isLocked: Bool
        /// The group draws only inside the shape below it.
        public var isClipped = false
        /// There is a shape below the group to clip it to.
        public var canClip = false
    }

    /// One row of the tree as the panel lists it.
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case layer
            /// A group of shapes in `layer`.
            case group
        }

        public var kind: Kind
        /// The layer the row is, or (for groups) is in.
        public var layer: LayerItem
        public var group: GroupLayer?
        /// 0 for layers, 1 for groups.
        public var depth: Int
        /// True when the row has rows under it to show, and they are shown.
        public var canExpand: Bool
        public var isExpanded: Bool

        public var id: String {
            switch kind {
            case .layer: "layer-\(layer.id)"
            case .group: "group-\(group?.id ?? 0)"
            }
        }
    }

    /// The presentation's name, shown on the root row.
    public var name: String
    /// Every layer, front to back, each holding its groups.
    public var layers: [LayerItem]
    /// Top to bottom.
    public var references: [ReferenceImage]

    public init(drawing: Drawing) {
        name = drawing.name
        layers = drawing.layers.reversed().map { source in
            var layer = LayerItem(id: source.id, name: source.name, shapeCount: source.shapes.count, isHidden: source.isHidden,
                                  isLocked: source.isLocked,
                                  hasHiddenOrLockedShapes: source.shapes.contains { $0.isHidden || $0.isLocked })
            layer.groups = source.groupRuns.reversed().map { run in
                GroupLayer(id: run.group.id, layer: source.id, name: run.group.name, shapeCount: run.indices.count,
                           isHidden: run.indices.allSatisfy { source.shapes[$0].isHidden },
                           isLocked: run.indices.allSatisfy { source.shapes[$0].isLocked },
                           isClipped: run.group.isClipped, canClip: (run.indices.first ?? 0) > 0)
            }
            return layer
        }
        references = drawing.references.reversed()
    }

    /// The tree as rows, front to back, with the layers whose row ids are in `expanded`
    /// open to their groups.
    public func treeRows(expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        for layer in layers {
            var row = Row(kind: .layer, layer: layer, depth: 0, canExpand: !layer.groups.isEmpty, isExpanded: false)
            row.isExpanded = row.canExpand && expanded.contains(row.id)
            rows.append(row)
            guard row.isExpanded else { continue }
            for group in layer.groups {
                rows.append(Row(kind: .group, layer: layer, group: group, depth: 1, canExpand: false, isExpanded: false))
            }
        }
        return rows
    }
}
