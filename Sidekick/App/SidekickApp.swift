import SwiftUI
import SwiftData

@main
struct SidekickApp: App {
    let container: ModelContainer = {
        let schema = Schema([WorkTask.self, ChatMessage.self, ToolStep.self, Attachment.self, Artifact.self, MemoryItem.self])
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
            Self.reconcileInterruptedTasks(in: container)
            return container
        } catch {
            fatalError("Could not create model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }

    /// Runs and approvals live only in memory, so any task still marked active after a relaunch was interrupted.
    @MainActor
    private static func reconcileInterruptedTasks(in container: ModelContainer) {
        let context = container.mainContext
        let active = [TaskStatus.running.rawValue, TaskStatus.waitingApproval.rawValue]
        let descriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { active.contains($0.statusRaw) })
        guard let tasks = try? context.fetch(descriptor), !tasks.isEmpty else { return }
        for task in tasks {
            task.status = .failed
            task.lastError = "Interrupted when the app closed. Send a follow-up to continue."
            for step in task.messages.flatMap(\.steps) where step.status == .running {
                step.status = .failed
            }
        }
        try? context.save()
    }
}

struct RootView: View {
    @State private var settings = AppSettings.shared
    @State private var router = Router()

    var body: some View {
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "sparkles") }
                .tag(Router.Tab.home)
            TaskListView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(Router.Tab.tasks)
            LibraryView()
                .tabItem { Label("Library", systemImage: "folder") }
                .tag(Router.Tab.library)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        .environment(settings)
        .environment(router)
        .environment(AgentRunner.shared)
        .sheet(isPresented: Binding(get: { !settings.hasOnboarded }, set: { if !$0 { settings.hasOnboarded = true } })) {
            OnboardingView()
                .environment(settings)
                .interactiveDismissDisabled()
        }
        .tint(Theme.accent)
    }
}

@Observable
final class Router {
    enum Tab: Hashable { case home, tasks, library, settings }
    var tab: Tab = .home
    var homePath: [WorkTask] = []
    var tasksPath: [WorkTask] = []

    func open(_ task: WorkTask) {
        switch tab {
        case .tasks: tasksPath = [task]
        default:
            tab = .home
            homePath = [task]
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.98)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let background = Color(.systemGroupedBackground)
}
