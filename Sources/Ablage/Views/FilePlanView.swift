import SwiftUI

extension FilePlan {
    var color: Color { isDestructive || state == .textFailed ? Palette.red : (hasAction ? Palette.blue : .secondary) }
}

struct FilePlanDetails: View {
    @EnvironmentObject private var state: AppState
    let item: InboxItem
    var showsFilename = true
    var compact = false
    private var plan: FilePlan { item.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if showsFilename {
                Text(item.name).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !compact {
                HStack(spacing: 6) {
                    Image(systemName: plan.symbol)
                    Text("Planned action").fontWeight(.semibold)
                }.foregroundStyle(plan.color)
            }
            if plan.steps.isEmpty { Text(plan.summary).font(.callout).fontWeight(.medium) }
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.symbol).foregroundStyle(plan.color).frame(width: 16).padding(.top, 2)
                    if compact {
                        Text(step.title).font(.callout).fontWeight(.medium).frame(width: 125, alignment: .leading)
                        stepValue(step).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(.callout).fontWeight(.medium)
                            stepValue(step)
                        }
                    }
                }
            }
            if !plan.explanation.isEmpty { Text(plan.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if plan.state == .needsOCR || plan.state == .textFailed {
                Button(plan.state == .textFailed ? "Retry reading text" : "Read this file next") { state.engine.readTextNext(path: item.id) }
                    .controlSize(.small)
            }
            if let rule = plan.rule {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text("Rule").foregroundStyle(.secondary)
                    Text(rule).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.font(.caption)
            }
            ForEach(plan.notes, id: \.self) { note in Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("This is a preview. The plan is checked again when you file.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func stepValue(_ step: FilePlan.Step) -> some View {
        if !step.value.isEmpty {
            Text(step.kind == .move ? Paths.abbreviate(step.value) : step.value)
                .font(step.kind == .run ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
