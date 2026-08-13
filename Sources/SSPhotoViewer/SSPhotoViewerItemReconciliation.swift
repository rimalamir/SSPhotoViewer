/// Pure sequence reconciliation used by the pager when the host publishes a
/// new viewer value while the presentation is active.
///
/// Pagination remains append-only, but an existing position may be replaced
/// while an app-owned loader resolves a newer media rendition. Keeping this
/// operation outside the view makes the identity rule explicit and testable.
struct SSPhotoViewerItemReconciliation {
    struct Replacement {
        let index: Int
        let previous: SSPhotoViewerItem
        let incoming: SSPhotoViewerItem
    }

    let items: [SSPhotoViewerItem]
    let replacements: [Replacement]

    static func apply(
        incoming: [SSPhotoViewerItem],
        to existing: [SSPhotoViewerItem]
    ) -> Self {
        var result = existing
        var replacements: [Replacement] = []
        let overlap = min(incoming.count, result.count)

        for index in 0..<overlap {
            guard result[index] != incoming[index] else { continue }

            let previous = result[index]
            let next = incoming[index]
            result[index] = next
            replacements.append(
                Replacement(index: index, previous: previous, incoming: next)
            )
        }

        if incoming.count > result.count {
            var knownIDs = Set(result.map(\.id))
            let fresh = incoming.dropFirst(result.count).filter {
                knownIDs.insert($0.id).inserted
            }
            result.append(contentsOf: fresh)
        }

        return Self(items: result, replacements: replacements)
    }

    static func indexMap(
        for items: [SSPhotoViewerItem]
    ) -> [String: Int] {
        Dictionary(
            items.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
