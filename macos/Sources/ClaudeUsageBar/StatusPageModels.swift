import Foundation

/// Internal Codable DTOs that mirror the wire shape of `https://status.claude.com/api/v2/summary.json`
/// (Statuspage.io v2).
///
/// These types are intentionally kept separate from the domain types (`StatusPageSummary`,
/// `StatusComponent`, `StatusIncident`) so the wire format stays swappable behind the
/// `HTTPClient` boundary.

struct StatuspageSummaryDTO: Decodable {
    let components: [StatuspageComponentDTO]
    let incidents: [StatuspageIncidentDTO]
}

struct StatuspageComponentDTO: Decodable {
    let id: String
    let name: String
    let status: String
    let groupId: String?
    let updatedAt: Date?
}

struct StatuspageIncidentDTO: Decodable {
    let id: String
    let name: String
    let status: String
    let impact: String
    let shortlink: URL?
    let updatedAt: Date?
}

extension StatuspageSummaryDTO {
    /// Map the wire DTO to domain types using the forgiving status decoder
    /// (unknown enum values fall back to `.operational`).
    func toDomain() -> StatusPageSummary {
        let components = self.components.map { dto in
            StatusComponent(
                id: dto.id,
                name: dto.name,
                status: ClaudeServiceStatus(forgiving: dto.status),
                groupId: dto.groupId,
                updatedAt: dto.updatedAt
            )
        }
        let incidents = self.incidents.map { dto in
            StatusIncident(
                id: dto.id,
                name: dto.name,
                status: dto.status,
                impact: dto.impact,
                shortlink: dto.shortlink,
                updatedAt: dto.updatedAt
            )
        }
        return StatusPageSummary(components: components, incidents: incidents)
    }
}
