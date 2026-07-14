import SwiftUI
import PolyShelfCore

struct SettingsView: View {
    var body: some View {
        TabView {
            FormatsSettingsView()
                .tabItem { Label("Formats", systemImage: "doc.badge.gearshape") }
            AISettingsView()
                .tabItem { Label("AI Tagging", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 480)
    }
}

/// Format registry toggles (FR-3.1). Enabled set persisted in UserDefaults;
/// toggling off hides items without deleting metadata (FR-3.3).
struct FormatsSettingsView: View {
    @AppStorage("enabledFormats") private var enabledFormatsData = Data()

    private var enabledExtensions: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: enabledFormatsData))
                ?? FormatRegistry.defaultEnabledExtensions
        }
    }

    var body: some View {
        Form {
            ForEach(FormatGroup.allCases, id: \.self) { group in
                let specs = FormatRegistry.all.filter { $0.group == group }
                if !specs.isEmpty {
                    Section(group.rawValue) {
                        ForEach(specs, id: \.ext) { spec in
                            Toggle(".\(spec.ext)", isOn: binding(for: spec.ext))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for ext: String) -> Binding<Bool> {
        Binding(
            get: { enabledExtensions.contains(ext) },
            set: { isOn in
                var set = enabledExtensions
                if isOn { set.insert(ext) } else { set.remove(ext) }
                enabledFormatsData = (try? JSONEncoder().encode(set)) ?? Data()
            }
        )
    }
}
