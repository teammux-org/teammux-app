import Foundation

// MARK: - RoleDivision

/// The division a role belongs to, matching the `division` field in role TOML files.
/// Raw values are the exact strings used in TOML (e.g. "project-management").
enum RoleDivision: String, CaseIterable, Sendable {
    case engineering
    case design
    case product
    case testing
    case projectManagement = "project-management"
    case strategy
    case specialized

    var displayName: String {
        switch self {
        case .engineering:       return "Engineering"
        case .design:            return "Design"
        case .product:           return "Product"
        case .testing:           return "Testing"
        case .projectManagement: return "Project Management"
        case .strategy:          return "Strategy"
        case .specialized:       return "Specialized"
        }
    }
}

// MARK: - RoleDefinition

/// A resolved role definition, bridged from `tm_role_t` in teammux.h.
/// `id` is the role identifier (e.g. "frontend-engineer") and serves as `Identifiable.id`.
struct RoleDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let division: String
    let emoji: String
    let description: String
    let writePatterns: [String]
    let denyWritePatterns: [String]
}
