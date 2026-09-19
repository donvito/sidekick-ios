import SwiftUI
import SwiftData

@main
struct SidekickApp: App {
    let container: ModelContainer = {
        let schema = Schema([WorkTask.self, ChatMessage.self, ToolStep.self, Attachment.self, Artifact.self, MemoryItem.self])
        do {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
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
