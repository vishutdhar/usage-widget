import SwiftUI
import UsageAgentCore
import UsageCore

/// The agent's only window: when it last wrote, what went wrong, whether
/// Codex is shown, and whether it starts at login.
struct StatusView: View {
    let controller: AgentController
    /// Stop asks first: a stray click (or an automated one) must not stop
    /// the agent, which launchd would otherwise not bring back.
    @State private var confirmingStop = false

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
                    LabeledContent("Reload tokens") {
                        Text("\(budget.tokens) of \(Int(ReloadBucket.capacity))").monospacedDigit()
                    }
                    LabeledContent("Next token") {
                        if let next = budget.nextToken {
                            Text(next.formatted(date: .omitted, time: .shortened))
                        } else {
                            Text("Full").foregroundStyle(.secondary)
                        }
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
                Text("While on, Usage Widget also restarts after a crash. Turning it off stops Usage Widget now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let note = controller.loginItemNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let note = controller.supervisionNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
                    Button("Stop\u{2026}") { confirmingStop = true }
                }
                .confirmationDialog("Stop Usage Widget until you open it again or log in?",
                                    isPresented: $confirmingStop) {
                    Button("Stop", role: .destructive) { controller.stop() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The widget stops updating.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
