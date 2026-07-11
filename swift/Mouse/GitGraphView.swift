import SwiftUI

/// The Graph container (kind 4): the ring's workspace as a commit graph — colored branch rails,
/// dots for commits, rings for merges, branch tips labeled. History comes from the GitHub API
/// (the workspace has no .git until libgit2 arrives; when it does, only the data source changes).
/// Vertical scroll only, per the gesture law.

struct CommitNode: Sendable {
    let sha: String
    let message: String
    let author: String
    let parents: [String]
}

/// One rendered row of the graph: which column the commit's dot sits in, the rail state around
/// it, and which rails curve in (children joining) or out (merge parents opening).
struct GraphRow: Identifiable {
    let commit: CommitNode
    let column: Int
    let lanesBefore: [String?]
    let lanesAfter: [String?]
    let joins: [Int]
    let opens: [Int]
    var id: String { commit.sha }
}

enum GitGraph {
    /// Classic commit-graph lane assignment, newest first: each rail carries the sha it expects
    /// next. A commit lands on the first rail expecting it (other expecting rails curve in and
    /// close — branch points), or opens a new rail (a branch tip). Its first parent inherits the
    /// rail; extra parents (merges) connect to existing rails or open new ones.
    static func layout(_ commits: [CommitNode]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        for commit in commits {
            let lanesBefore = lanes
            var joins: [Int] = []
            let column: Int
            let expecting = lanes.indices.filter { lanes[$0] == commit.sha }
            if let first = expecting.first {
                column = first
                for other in expecting.dropFirst() {
                    lanes[other] = nil
                    joins.append(other)
                }
            } else {
                if let free = lanes.firstIndex(where: { $0 == nil }) {
                    column = free
                } else {
                    column = lanes.count
                    lanes.append(nil)
                }
            }
            lanes[column] = commit.parents.first

            var opens: [Int] = []
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.firstIndex(of: parent) {
                    opens.append(existing)
                } else if let free = lanes.firstIndex(where: { $0 == nil }), free != column {
                    lanes[free] = parent
                    opens.append(free)
                } else {
                    lanes.append(parent)
                    opens.append(lanes.count - 1)
                }
            }
            rows.append(GraphRow(
                commit: commit, column: column,
                lanesBefore: lanesBefore, lanesAfter: lanes,
                joins: joins, opens: opens
            ))
        }
        return rows
    }

    /// Rail palette — cycles by column.
    static let railColors: [Color] = [.orange, .pink, .cyan, .green, .purple, .yellow, .blue, .red]

    static func color(_ lane: Int) -> Color { railColors[lane % railColors.count] }

    // MARK: - GitHub history fetch

    struct History: Sendable {
        let commits: [CommitNode]
        /// Branch tip labels, keyed by sha.
        let branchTips: [String: String]
    }

    static func fetchHistory(repo: String, token: String) async throws -> History {
        async let commitsData = get("https://api.github.com/repos/\(repo)/commits?per_page=80", token: token)
        async let branchesData = get("https://api.github.com/repos/\(repo)/branches?per_page=50", token: token)

        struct APICommit: Decodable {
            struct Inner: Decodable {
                struct Person: Decodable { let name: String? }
                let message: String
                let author: Person?
            }
            struct Parent: Decodable { let sha: String }
            let sha: String
            let commit: Inner
            let parents: [Parent]
        }
        struct APIBranch: Decodable {
            struct Tip: Decodable { let sha: String }
            let name: String
            let commit: Tip
        }

        let decoder = JSONDecoder()
        let commits = try decoder.decode([APICommit].self, from: await commitsData).map {
            CommitNode(
                sha: $0.sha,
                message: $0.commit.message.components(separatedBy: "\n")[0],
                author: $0.commit.author?.name ?? "",
                parents: $0.parents.map(\.sha)
            )
        }
        var tips: [String: String] = [:]
        if let branches = try? decoder.decode([APIBranch].self, from: await branchesData) {
            for branch in branches { tips[branch.commit.sha] = branch.name }
        }
        return History(commits: commits, branchTips: tips)
    }

    private static func get(_ urlString: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) for history")
        }
        return data
    }
}

struct GitGraphContainerView: View {
    let workspace: Workspace?

    private let laneWidth: CGFloat = 14
    private let rowHeight: CGFloat = 34

    var body: some View {
        Group {
            if let workspace {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(workspace.repoFullName) — history")
                        .font(.custom(AppFont.asciiName, size: 11))
                        .opacity(0.55)
                        .padding(.bottom, 8)
                    if let rows = workspace.graphRows {
                        graph(rows, tips: workspace.graphTips)
                    } else if let error = workspace.graphError {
                        Text(error)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.85)
                            .padding(.top, 8)
                    } else if GitHubAuth.shared.accessToken == nil {
                        Text("sign in with the GitHub container first")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.55)
                            .padding(.top, 8)
                    } else {
                        Text("loading…")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.55)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: workspace.repoFullName + "::t\(workspace.treeVersion)") {
                    // Fallback kick (deduped inside) — normally the action row has already
                    // loaded this long before the Graph is on screen.
                    if let token = GitHubAuth.shared.accessToken {
                        await workspace.refreshHistory(token: token)
                    }
                }
            } else {
                Text("open a repo in the Files container")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private func graph(_ rows: [GraphRow], tips: [String: String]) -> some View {
        let laneCount = min(rows.map { max($0.lanesBefore.count, $0.lanesAfter.count) }.max() ?? 1, 8)
        let railsWidth = CGFloat(laneCount) * laneWidth + 4
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        rails(row)
                            .frame(width: railsWidth, height: rowHeight)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                if let tip = tips[row.commit.sha] {
                                    Text(tip)
                                        .font(.custom(AppFont.asciiName, size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(GitGraph.color(row.column).opacity(0.35), in: Capsule())
                                }
                                Text(row.commit.message)
                                    .font(.custom(AppFont.asciiName, size: 12))
                                    .lineLimit(1)
                            }
                            Text("\(String(row.commit.sha.prefix(7)))  \(row.commit.author)")
                                .font(.custom(AppFont.asciiName, size: 10))
                                .opacity(0.4)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: rowHeight)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// One row's slice of the rails: pass-through verticals, curves for joins (children closing
    /// into this commit) and opens (merge parents fanning out), and the commit dot — a ring for
    /// merges, filled otherwise.
    private func rails(_ row: GraphRow) -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            let x: (Int) -> CGFloat = { CGFloat($0) * self.laneWidth + self.laneWidth / 2 }
            let dotX = x(row.column)

            func stroke(_ path: Path, _ lane: Int) {
                context.stroke(path, with: .color(GitGraph.color(lane)), lineWidth: 2)
            }

            // Pass-through rails (active before and after, not this commit's column).
            for lane in 0..<max(row.lanesBefore.count, row.lanesAfter.count) where lane != row.column {
                let activeBefore = lane < row.lanesBefore.count && row.lanesBefore[lane] != nil
                let activeAfter = lane < row.lanesAfter.count && row.lanesAfter[lane] != nil
                if activeBefore && activeAfter && !row.joins.contains(lane) && !row.opens.contains(lane) {
                    stroke(Path { $0.move(to: CGPoint(x: x(lane), y: 0)); $0.addLine(to: CGPoint(x: x(lane), y: size.height)) }, lane)
                }
            }
            // The commit's own rail: from children above, to first parent below.
            if row.lanesBefore.indices.contains(row.column), row.lanesBefore[row.column] != nil {
                stroke(Path { $0.move(to: CGPoint(x: dotX, y: 0)); $0.addLine(to: CGPoint(x: dotX, y: midY)) }, row.column)
            }
            if row.lanesAfter.indices.contains(row.column), row.lanesAfter[row.column] != nil {
                stroke(Path { $0.move(to: CGPoint(x: dotX, y: midY)); $0.addLine(to: CGPoint(x: dotX, y: size.height)) }, row.column)
            }
            // Children rails curving in to end at this commit.
            for lane in row.joins {
                stroke(Path {
                    $0.move(to: CGPoint(x: x(lane), y: 0))
                    $0.addQuadCurve(to: CGPoint(x: dotX, y: midY), control: CGPoint(x: x(lane), y: midY))
                }, lane)
            }
            // Merge parents fanning out below (and continuing on their rail).
            for lane in row.opens {
                stroke(Path {
                    $0.move(to: CGPoint(x: dotX, y: midY))
                    $0.addQuadCurve(to: CGPoint(x: x(lane), y: size.height), control: CGPoint(x: x(lane), y: midY))
                }, lane)
            }
            // The dot: merges are rings, commits are filled.
            let radius: CGFloat = 4.5
            let dotRect = CGRect(x: dotX - radius, y: midY - radius, width: radius * 2, height: radius * 2)
            if row.commit.parents.count > 1 {
                context.stroke(Path(ellipseIn: dotRect), with: .color(GitGraph.color(row.column)), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: dotRect), with: .color(GitGraph.color(row.column)))
            }
        }
    }

}
