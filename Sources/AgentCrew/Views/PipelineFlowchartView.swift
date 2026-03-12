import SwiftUI

// MARK: - Data Structures

private struct FlowNode: Identifiable {
    let id: UUID
    let name: String
    let tool: ToolType?
    let stageID: UUID
    let stageName: String
    let status: StepStatus
    let waveIndex: Int
    let laneIndex: Int
    let laneCount: Int
    let dependencies: Set<UUID>
}

private struct FlowEdge: Identifiable {
    let id: String
    let from: UUID
    let to: UUID
    let isImplicit: Bool
}

// MARK: - Wave Computation

private func computeWaves(from pipeline: Pipeline) -> [[ResolvedStep]] {
    let allSteps = pipeline.allStepsWithResolvedDependencies()
    guard !allSteps.isEmpty else { return [] }

    var finalized: Set<UUID> = []
    var remaining = allSteps
    var waves: [[ResolvedStep]] = []

    while !remaining.isEmpty {
        let ready = remaining.filter { resolved in
            resolved.allDependencies.allSatisfy { finalized.contains($0) }
        }
        guard !ready.isEmpty else { break }
        waves.append(ready)
        for r in ready { finalized.insert(r.step.id) }
        remaining.removeAll { resolved in finalized.contains(resolved.step.id) }
    }
    return waves
}

// MARK: - Layout Constants

private enum FlowLayout {
    static let nodeWidth: CGFloat = 180
    static let nodeHeight: CGFloat = 60
    static let waveSpacingY: CGFloat = 80
    static let laneSpacingX: CGFloat = 220
    static let topPadding: CGFloat = 20
    static let leftMargin: CGFloat = 80
}

// MARK: - Main View

struct PipelineFlowchartView: View {
    let pipeline: Pipeline
    @EnvironmentObject var vm: AppViewModel

    @State private var hoveredNodeID: UUID?
    @State private var lockedNodeID: UUID?

    private var waves: [[ResolvedStep]] {
        computeWaves(from: pipeline)
    }

    private var nodes: [FlowNode] {
        var result: [FlowNode] = []
        let stageMap = Dictionary(uniqueKeysWithValues: pipeline.stages.map { ($0.id, $0) })

        for (waveIndex, wave) in waves.enumerated() {
            let laneCount = wave.count
            for (laneIndex, resolved) in wave.enumerated() {
                let status = vm.stepStatuses[resolved.step.id]
                    ?? latestStepStatus(resolved.step.id)
                    ?? resolved.step.status
                let stageName = stageMap[resolved.stageID]?.name ?? "Stage"
                result.append(FlowNode(
                    id: resolved.step.id,
                    name: resolved.step.name,
                    tool: resolved.step.displayTool,
                    stageID: resolved.stageID,
                    stageName: stageName,
                    status: status,
                    waveIndex: waveIndex,
                    laneIndex: laneIndex,
                    laneCount: laneCount,
                    dependencies: resolved.allDependencies
                ))
            }
        }
        return result
    }

    private var edges: [FlowEdge] {
        var result: [FlowEdge] = []
        let nodeIDs = Set(nodes.map(\.id))
        for node in nodes {
            for dep in node.dependencies where nodeIDs.contains(dep) {
                let explicitDeps = pipeline.allSteps
                    .first(where: { $0.id == node.id })?
                    .dependsOnStepIDs ?? []
                let isImplicit = !explicitDeps.contains(dep)
                result.append(FlowEdge(
                    id: "\(dep)-\(node.id)",
                    from: dep,
                    to: node.id,
                    isImplicit: isImplicit
                ))
            }
        }
        return result
    }

    private var maxLaneCount: Int {
        waves.map(\.count).max() ?? 1
    }

    private var canvasSize: CGSize {
        let w = FlowLayout.leftMargin + CGFloat(max(maxLaneCount, 1)) * FlowLayout.laneSpacingX + FlowLayout.nodeWidth / 2 + 24
        let h = FlowLayout.topPadding
            + CGFloat(waves.count) * (FlowLayout.nodeHeight + FlowLayout.waveSpacingY)
            + 40
        return CGSize(width: max(w, 500), height: max(h, 300))
    }

    private var highlightedNodeID: UUID? {
        lockedNodeID ?? hoveredNodeID
    }

    private var focusHintText: String {
        if let lockedNodeID,
           let name = nodes.first(where: { $0.id == lockedNodeID })?.name {
            return "Path locked on '\(name)'. Click node again to unlock."
        }
        return "Hover a node to inspect dependencies. Click a node to lock path highlighting."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if nodes.isEmpty {
                emptyState
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        edgesLayer
                        nodesLayer
                        waveLabelsLayer
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if lockedNodeID == nil {
                                hoveredNodeID = hoveredNode(at: location)
                            }
                        case .ended:
                            if lockedNodeID == nil {
                                hoveredNodeID = nil
                            }
                        }
                    }
                    .highPriorityGesture(SpatialTapGesture().onEnded { value in
                        let tappedNode = hoveredNode(at: value.location)
                        if let tappedNode {
                            if lockedNodeID == tappedNode {
                                lockedNodeID = nil
                            } else {
                                lockedNodeID = tappedNode
                            }
                            hoveredNodeID = tappedNode
                        } else {
                            lockedNodeID = nil
                            hoveredNodeID = nil
                        }
                    })
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 560, idealHeight: 780)
        .onChange(of: nodes.map(\.id)) { _, ids in
            if let lockedNodeID, !ids.contains(lockedNodeID) {
                self.lockedNodeID = nil
            }
            if let hoveredNodeID, !ids.contains(hoveredNodeID) {
                self.hoveredNodeID = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.blue.gradient)

            VStack(alignment: .leading, spacing: 2) {
                Text("Execution Flowchart")
                    .font(.headline)
                Text("\(pipeline.name) — \(waves.count) waves, \(nodes.count) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(focusHintText)
                    .font(.caption2)
                    .foregroundStyle(lockedNodeID == nil ? Color.secondary : Color.cyan)
            }

            Spacer()

            legend
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: .secondary, label: "Pending")
            legendItem(color: .blue, label: "Running")
            legendItem(color: .green, label: "Completed")
            legendItem(color: .red, label: "Failed")
            legendItem(color: .orange, label: "Skipped")
        }
        .fixedSize()
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Steps",
            systemImage: "point.3.connected.trianglepath.dotted",
            description: Text("Add stages and steps to see the execution flowchart.")
        )
    }

    // MARK: - Wave Labels (horizontal)

    private var waveLabelsLayer: some View {
        ForEach(Array(waves.enumerated()), id: \.offset) { waveIndex, _ in
            Text("Wave \(waveIndex + 1)")
                .font(.caption.bold())
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.1).gradient, in: Capsule())
                .fixedSize()
                .position(
                    x: FlowLayout.leftMargin / 2,
                    y: FlowLayout.topPadding
                        + CGFloat(waveIndex) * (FlowLayout.nodeHeight + FlowLayout.waveSpacingY)
                        + FlowLayout.nodeHeight / 2
                )
        }
    }

    // MARK: - Edges Layer

    private var edgesLayer: some View {
        let positionMap = nodePositionMap()
        return Canvas { context, _ in
            for edge in edges {
                guard let fromPos = positionMap[edge.from],
                      let toPos = positionMap[edge.to] else { continue }

                let startPoint = CGPoint(x: fromPos.x, y: fromPos.y + FlowLayout.nodeHeight / 2)
                let endPoint = CGPoint(x: toPos.x, y: toPos.y - FlowLayout.nodeHeight / 2)

                var path = Path()
                path.move(to: startPoint)

                let midY = (startPoint.y + endPoint.y) / 2
                path.addCurve(
                    to: endPoint,
                    control1: CGPoint(x: startPoint.x, y: midY),
                    control2: CGPoint(x: endPoint.x, y: midY)
                )

                let isHighlighted = highlightedNodeID == edge.from || highlightedNodeID == edge.to
                let strokeColor = isHighlighted ? Color.cyan : (edge.isImplicit ? Color.secondary.opacity(0.35) : Color.secondary.opacity(0.55))
                let lineWidth: CGFloat = isHighlighted ? 3.0 : 1.5

                context.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        dash: edge.isImplicit ? [6, 4] : []
                    )
                )

                drawArrowHead(context: context, at: endPoint, from: CGPoint(x: endPoint.x, y: midY), color: strokeColor)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private func drawArrowHead(context: GraphicsContext, at tip: CGPoint, from control: CGPoint, color: Color) {
        let angle = atan2(tip.y - control.y, tip.x - control.x)
        let arrowLength: CGFloat = 8
        let arrowAngle: CGFloat = .pi / 6

        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - arrowLength * cos(angle - arrowAngle),
            y: tip.y - arrowLength * sin(angle - arrowAngle)
        ))
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - arrowLength * cos(angle + arrowAngle),
            y: tip.y - arrowLength * sin(angle + arrowAngle)
        ))

        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    // MARK: - Nodes Layer

    private var nodesLayer: some View {
        let positionMap = nodePositionMap()
        return ForEach(nodes) { node in
            if let pos = positionMap[node.id] {
                FlowNodeView(
                    node: node,
                    isHovered: highlightedNodeID == node.id
                )
                .position(x: pos.x, y: pos.y)
            }
        }
    }

    // MARK: - Helpers

    private func nodePositionMap() -> [UUID: CGPoint] {
        var map: [UUID: CGPoint] = [:]
        let lanesWidth = CGFloat(max(maxLaneCount, 1)) * FlowLayout.laneSpacingX

        for node in nodes {
            let laneWidth = lanesWidth / CGFloat(node.laneCount)
            let x = FlowLayout.leftMargin + laneWidth * (CGFloat(node.laneIndex) + 0.5)
            let y = FlowLayout.topPadding + CGFloat(node.waveIndex) * (FlowLayout.nodeHeight + FlowLayout.waveSpacingY) + FlowLayout.nodeHeight / 2
            map[node.id] = CGPoint(x: x, y: y)
        }
        return map
    }

    private func latestStepStatus(_ stepID: UUID) -> StepStatus? {
        vm.latestStepStatus(pipelineID: pipeline.id, stepID: stepID)
    }

    private func hoveredNode(at location: CGPoint) -> UUID? {
        let positions = nodePositionMap()
        for node in nodes.reversed() {
            guard let center = positions[node.id] else { continue }
            let rect = CGRect(
                x: center.x - FlowLayout.nodeWidth / 2,
                y: center.y - FlowLayout.nodeHeight / 2,
                width: FlowLayout.nodeWidth,
                height: FlowLayout.nodeHeight
            )
            if rect.contains(location) {
                return node.id
            }
        }
        return nil
    }
}

// MARK: - Flow Node View

private struct FlowNodeView: View {
    let node: FlowNode
    let isHovered: Bool

    private var statusColor: Color {
        switch node.status {
        case .pending:   .secondary
        case .running:   .blue
        case .completed: .green
        case .failed:    .red
        case .skipped:   .orange
        }
    }

    private var borderColor: Color {
        if isHovered { return .blue }
        return statusColor.opacity(0.6)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                if let tool = node.tool {
                    Image(systemName: tool.iconName)
                        .font(.caption)
                        .foregroundStyle(tool.tintColor)
                }

                Text(node.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text(node.stageName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 4) {
                if node.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                Text(node.status.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: FlowLayout.nodeWidth, height: FlowLayout.nodeHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
                .shadow(color: statusColor.opacity(isHovered ? 0.3 : 0.12), radius: isHovered ? 6 : 3, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: isHovered ? 2 : 1.2)
        }
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}
