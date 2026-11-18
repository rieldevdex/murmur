import SwiftUI
import AppKit

// MARK: - Today: the planner's tasks for today, the timer, and what's next
//
// Tasks come from the planner (PlannerStore), so ticking one off here ticks it off there too.
// The ear beside the notch switches between Tasks and the full Timer.

struct TodayView: View {
    @ObservedObject private var store = PlannerStore.shared
    @ObservedObject private var timer = IslandTimer.shared
    @AppStorage("todayMode") private var mode = "tasks"
    @State private var draft = ""
    @State private var nextEvent: String?
    @State private var justFinished = false
    @FocusState private var typing: Bool

    var body: some View {
        let _ = store.version          // redraw when the planner changes
        let tasks = store.today()
        VStack(alignment: .leading, spacing: 7) {
            summary(tasks)
            if store.hasData {
                list(tasks)
            } else {
                empty
            }
            addField
            footer
        }
        .onAppear {
            store.load()
            nextEvent = Greeter.shared.nextEventText()
        }
        .onDisappear { NotchController.shared.endTyping() }
    }

    // MARK: The line above the list

    private func summary(_ tasks: [PlannerStore.Item]) -> some View {
        let done = tasks.filter(\.done).count
        let overdue = store.overdueCount()
        return HStack(spacing: 8) {
            if !tasks.isEmpty {
                ProgressRing(progress: Double(done) / Double(tasks.count))
                    .frame(width: 13, height: 13)
                Text(done == tasks.count ? "All done today" : "\(done) of \(tasks.count) done")
                    .foregroundStyle(done == tasks.count ? Color.green.opacity(0.9) : IslandType.secondary)
            } else if store.hasData {
                Text("Nothing planned today").foregroundStyle(IslandType.secondary)
            }
            if overdue > 0 {
                Text("· \(overdue) from earlier")
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .help("Unfinished tasks from earlier days. Open the planner to move them to today.")
            }
            Spacer(minLength: 0)
            if let exam = store.nextExam() {
                HStack(spacing: 4) {
                    Circle().fill(exam.colour ?? .white).frame(width: 6, height: 6)
                    Text(exam.days == 0 ? "\(exam.subject) exam today" :
                         exam.days == 1 ? "\(exam.subject) exam tomorrow" : "\(exam.subject) in \(exam.days) days")
                }
                .foregroundStyle(IslandType.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 2)
    }

    // MARK: Tasks

    private func list(_ tasks: [PlannerStore.Item]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(tasks) { task in
                    TaskRow(task: task) {
                        let finishing = !task.done
                        withAnimation(Motion.spring(0.35, 0.8)) { store.toggle(task.id) }
                        if finishing {
                            NotchController.haptic(.levelChange)
                            if store.today().allSatisfy(\.done) { NotchController.haptic(.levelChange) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Your planner lives in Murmur now")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("Open it, then paste a backup from the old planner under Exams & settings › Backup.")
                .font(.system(size: 10.5))
                .foregroundStyle(IslandType.tertiary)
                .multilineTextAlignment(.center)
            Button("Open Planner") {
                NotchController.shared.collapse()
                PlannerWindow.shared.show()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Quick add

    private var addField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IslandType.tertiary)
            TextField("Add a task for today (!8 sets urgency)", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .focused($typing)
                .onSubmit {
                    let text = draft
                    draft = ""
                    withAnimation(Motion.spring(0.35, 0.85)) { store.add(text) }
                }
                .onExitCommand {
                    draft = ""
                    typing = false
                    NotchController.shared.endTyping()
                }
            Button {
                NotchController.shared.collapse()
                PlannerWindow.shared.show()
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandType.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Open the planner")
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(typing ? 0.13 : 0.07)))
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded {
            NotchController.shared.beginTyping()
            DispatchQueue.main.async { typing = true }
        })
    }

    // MARK: Timer and what's next

    private var footer: some View {
        HStack(spacing: 8) {
            if timer.isActive {
                runningTimer
            } else {
                ForEach(Array(timer.presets.prefix(2))) { preset in
                    chip(preset.title) { timer.start(preset) }
                }
                chip("Timer…") { withAnimation(.easeInOut(duration: 0.2)) { mode = "timer" } }
            }
            Spacer(minLength: 0)
            if let e = nextEvent {
                Label(e, systemImage: "calendar.badge.clock")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(IslandType.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
    }

    private var runningTimer: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { t in
            let colour = TimerColour.of(timer.phase)
            HStack(spacing: 7) {
                TimerRing(progress: timer.progress(at: t.date), colour: colour, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
                Text(IslandTimer.format(timer.remaining(at: t.date)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
                Text(timer.phase?.name ?? "")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(colour)
                    .lineLimit(1)
                Button {
                    NotchController.haptic(.generic)
                    timer.toggle()
                } label: {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 22, height: 18)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(PressableStyle())
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { mode = "timer" } }
            .help("Show the timer")
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}

private struct TaskRow: View {
    let task: PlannerStore.Item
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .strokeBorder(task.done ? Color.clear : (task.colour ?? Color.white.opacity(0.5)), lineWidth: 1.5)
                    if task.done {
                        Circle().fill(task.colour ?? Color.white.opacity(0.7))
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.8))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(PressableStyle())
            .help(task.done ? "Mark not done" : "Mark done")

            Text(task.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(task.done ? IslandType.tertiary : Color.white)
                .strikethrough(task.done, color: IslandType.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(task.title)

            Spacer(minLength: 4)

            if task.steps.total > 0 && !task.done {
                Text("\(task.steps.done)/\(task.steps.total)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(IslandType.tertiary)
            }
            if task.repeats {
                Image(systemName: "repeat")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(IslandType.tertiary)
            }
            Text("\(task.urgency)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(minWidth: 18, minHeight: 15)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.band(task.urgency)))
                .opacity(task.done ? 0.4 : 1)
                .help("Urgency \(task.urgency) of 10")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
    }

    static func band(_ u: Int) -> Color { UrgencyColour.of(u) }
}

/// The planner's colours for urgency (9–10 red, 7–8 orange, 4–6 amber, 1–3 grey)
enum UrgencyColour {
    static func of(_ u: Int) -> Color {
        u >= 9 ? Color(red: 0.78, green: 0.19, blue: 0.17)
            : u >= 7 ? Color(red: 0.83, green: 0.40, blue: 0.16)
            : u >= 4 ? Color(red: 0.75, green: 0.56, blue: 0.12)
            : Color(red: 0.50, green: 0.58, blue: 0.59)
    }
}

/// A small progress ring for "2 of 5 done"
private struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(progress >= 1 ? Color.green : Color.white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.spring(0.5, 0.8), value: progress)
        }
    }
}
