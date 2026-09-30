import SwiftUI
import UsageAgentCore

/// The agent's only window: when it last wrote, what went wrong, whether
/// Codex is shown, and whether it starts at login.
struct StatusView: View {
    let controller: AgentController

    var body: some View {
        Form {
            Section {
                LabeledContent("Last update") {
                    if let date = controller.lastWrite {
                        Text("\(date.formatted(date: .omitted, time: .standard)), \(Text(date, style: .relative)) ago")
                            .monospacedDigit()
                    } else {
                        Text("Not yet").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Last error") {
                    Text(controller.lastError ?? "None")
                        .foregroundStyle(controller.lastError == nil ? .secondary : .primary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if controller.helperWarnings > 0 {
                    Text("cswap left a helper holding its output \(controller.helperWarnings) \(controller.helperWarnings == 1 ? "time" : "times") since launch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let budget = controller.budget {
                    LabeledContent("Reload cap") {
                        Text("\(budget.cap) a day").monospacedDigit()
                    }
                    LabeledContent("Reloads in the last day") {
                        Text("\(budget.requests24h)").monospacedDigit()
                    }
                    LabeledContent("Next ordinary reload") {
                        if budget.nextOrdinary > Date() {
                            Text("From \(budget.nextOrdinary.formatted(date: .omitted, time: .shortened))")
                        } else {
                            Text("Now").foregroundStyle(.secondary)
                        }
                    }
                }
                if let stateError = controller.stateError {
                    Text(stateError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                Toggle("Show Codex", isOn: Binding(
                    get: { controller.showCodex },
                    set: { controller.setShowCodex($0) }
                ))
                Text("Reads Codex's session files. Asks Codex itself at start, when Codex has been idle for an hour (at most every 3 hours), and every 6 hours for the reset count, never more than 8 times a day.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if controller.showCodex {
                    LabeledContent("Codex checked") {
                        if let checked = controller.codexCheckedAt {
                            Text(checked.formatted(date: .omitted, time: .shortened))
                        } else {
                            Text("Not yet").foregroundStyle(.secondary)
                        }
                    }
                    if let next = controller.codexNextCheck {
                        LabeledContent("Next check") {
                            if next > Date() {
                                Text("From \(next.formatted(date: .omitted, time: .shortened))")
                            } else {
                                Text("When Codex is idle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error = controller.codexCallsError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if controller.showCodex, let error = controller.codexError {
                    LabeledContent("Codex error") {
                        Text(error)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                Toggle("Start at login", isOn: Binding(
                    get: { controller.loginItemStatus == .enabled },
                    set: { controller.setStartAtLogin($0) }
                ))
                if controller.loginItemStatus == .requiresApproval {
                    Text("Allow Usage Widget in System Settings, General, Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = controller.loginItemError {
                    Text("Could not change the login item: \(error)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Text("Add the widget from the desktop: Edit Widgets, then search for Usage.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
