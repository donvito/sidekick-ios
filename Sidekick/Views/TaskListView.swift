import SwiftUI
import SwiftData

struct TaskListView: View {
    @Query(sort: \WorkTask.updatedAt, order: .reverse) private var tasks: [WorkTask]
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Environment(AgentRunner.self) private var runner
    @State private var search = ""

    private var filtered: [WorkTask] {
        guard !search.isEmpty else { return tasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
    }

    private var active: [WorkTask] { filtered.filter { $0.status == .running || $0.status == .waitingApproval } }
    private var others: [WorkTask] { filtered.filter { $0.status != .running && $0.status != .waitingApproval } }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.tasksPath) {
            Group {
                if tasks.isEmpty {
                    ContentUnavailableView("No tasks yet", systemImage: "checklist", description: Text("Start something from the Home tab and it will show up here."))
                } else {
                    List {
                        if !active.isEmpty {
                            Section("In progress") {
                                ForEach(active) { task in
                                    NavigationLink(value: task) { TaskRow(task: task) }
                                }
                            }
                        }
                        Section(active.isEmpty ? "All tasks" : "Earlier") {
                            ForEach(others) { task in
                                NavigationLink(value: task) { TaskRow(task: task) }
                            }
                            .onDelete { offsets in
                                for i in offsets {
                                    let task = others[i]
                                    runner.cancel(task)
                                    modelContext.delete(task)
                                }
                                try? modelContext.save()
                            }
                        }
                    }
                    .searchable(text: $search)
                }
            }
            .navigationTitle("Tasks")
            .navigationDestination(for: WorkTask.self) { TaskDetailView(task: $0) }
        }
    }
}
