import Foundation

struct PrivacyRemovalStats: Codable, Equatable {
    static let storageKey = "picstrip.privacyRemovalStats"

    var metadataCategoryCounts: [String: Int] = [:]
    var visualTypeCounts: [String: Int] = [:]
    var visualConfidenceCounts: [String: Int] = [:]

    var totalMetadataFields: Int {
        metadataCategoryCounts.values.reduce(0, +)
    }

    var totalVisualRedactions: Int {
        visualTypeCounts.values.reduce(0, +)
    }

    var isEmpty: Bool {
        totalMetadataFields == 0 && totalVisualRedactions == 0
    }

    mutating func record(metadataFields: [MetadataField], visualRegions: [RedactionRegion]) {
        for field in metadataFields where !field.isStructural {
            metadataCategoryCounts[field.category, default: 0] += 1
        }

        for region in visualRegions {
            visualTypeCounts[region.displayName, default: 0] += 1
            if let confidence = region.confidence {
                visualConfidenceCounts[confidence.label, default: 0] += 1
            }
        }
    }

    mutating func record(reports: [AuditReport]) {
        for report in reports {
            for categoryReport in report.metadataStripped {
                metadataCategoryCounts[categoryReport.category, default: 0] += categoryReport.strippedFields.count
            }

            for visualReport in report.visualRedactions {
                visualTypeCounts[visualReport.type, default: 0] += visualReport.instanceCount
            }
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> PrivacyRemovalStats {
        guard let data = defaults.data(forKey: storageKey),
              let stats = try? JSONDecoder().decode(PrivacyRemovalStats.self, from: data) else {
            return PrivacyRemovalStats()
        }
        return stats
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
