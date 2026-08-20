import SwiftUI
import EnergyLab

/// What the detail column is showing.
enum LabSelection: Hashable {
    case scenario(String)
    case comparison
    case principles
}

@main
struct EnergyLabApp: App {
    @StateObject private var model = LabModel()

    var body: some Scene {
        WindowGroup("Energy Lab") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, idealWidth: 1220, maxWidth: .infinity,
                       minHeight: 640, idealHeight: 860, maxHeight: .infinity)
        }
        .commands {
            // Nothing here creates documents, so the default New Item command
            // would only be a dead menu entry.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LabModel
    @State private var selection: LabSelection? = .scenario("healthy")

    var body: some View {
        SplitLayout {
            ScenarioListView(selection: $selection)
        } detail: {
            DetailColumn(selection: selection)
        }
    }
}

/// The source-list layout.
///
/// `NavigationSplitView` is the right container for this and is used wherever
/// it exists, but it arrived in macOS 13 and this package deploys to macOS 12,
/// so the older two-column `NavigationView` stands in below that. Both produce
/// the same sidebar-and-detail arrangement.
struct SplitLayout<Sidebar: View, Detail: View>: View {
    let sidebar: Sidebar
    let detail: Detail

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 244, ideal: 268, max: 340)
            } detail: {
                detail
            }
        } else {
            NavigationView {
                sidebar
                    .frame(minWidth: 244, idealWidth: 268)
                detail
            }
        }
    }
}

/// Routes the sidebar selection to a view, and supplies the empty state when
/// nothing is selected.
struct DetailColumn: View {
    @EnvironmentObject private var model: LabModel
    let selection: LabSelection?

    var body: some View {
        switch selection {
        case .scenario(let id):
            if let scenario = Scenario.named(id) {
                ScenarioDetailView(scenario: scenario)
            } else {
                EmptyDetail(text: "That scenario is not in this build of the lab.")
            }
        case .comparison:
            EnergyComparisonView()
        case .principles:
            PrinciplesView()
        case .none:
            EmptyDetail(text: "Pick a scenario. Every one of them does the same nominal job; only the coordination differs.")
        }
    }
}

struct EmptyDetail: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.slate)
            Prose(text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
