import SwiftUI
import PolyShelfCore

/// Settings → AI Tagging (FR-5.5/5.8): user-supplied OpenAI-compatible
/// endpoint. Key goes to the Keychain; base URL/model to UserDefaults.
struct AISettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage("aiBaseURL") private var baseURL = ""
    @AppStorage("aiModel") private var model = ""
    @AppStorage("aiMaxConcurrent") private var maxConcurrent = 2
    @AppStorage("aiEnabled") private var aiEnabled = false
    @State private var apiKey = ""
    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var batchRunning = false
    @State private var batchProgress: AITaggingService.Progress?

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI tagging", isOn: $aiEnabled)
                Text("Nothing ever leaves this Mac except these opt-in AI calls: the rendered preview image, filename, and geometry stats are sent to the endpoint below. Your files are never uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Endpoint (OpenAI-compatible)") {
                TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:11434/v1"))
                    .disableAutocorrection(true)
                TextField("Model", text: $model, prompt: Text("llama3.2-vision"))
                    .disableAutocorrection(true)
                SecureField("API Key (stored in Keychain)", text: $apiKey)
                    .onSubmit(saveKey)
                Stepper("Concurrent requests: \(maxConcurrent)", value: $maxConcurrent, in: 1...8)
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") {
                        testConnection()
                    }
                    .disabled(testing || baseURL.isEmpty || model.isEmpty)
                    switch testResult {
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    case nil:
                        EmptyView()
                    }
                }
            }
            Section("Batch") {
                Button(batchRunning ? "Tagging…" : "Generate AI Tags for Untagged Models") {
                    runBatch()
                }
                .disabled(batchRunning || !aiEnabled || baseURL.isEmpty || model.isEmpty)
                if let progress = batchProgress {
                    ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1))) {
                        Text("\(progress.processed)/\(progress.total) tagged" + (progress.failed > 0 ? " · \(progress.failed) failed" : ""))
                            .font(.caption)
                    }
                }
                Text("Batch mode runs only when you start it here — never automatically during scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = KeychainStore.loadAPIKey() ?? "" }
        .onChange(of: apiKey) { saveKey() }
    }

    private func saveKey() {
        try? KeychainStore.saveAPIKey(apiKey)
    }

    private var client: AIClient {
        AIClient(config: AIEndpointConfig(baseURL: baseURL, model: model, maxConcurrent: maxConcurrent))
    }

    private func testConnection() {
        testing = true
        testResult = nil
        saveKey()
        let client = self.client
        Task {
            let error = await client.testConnection()
            testResult = error.map { .failure($0) } ?? .success
            testing = false
        }
    }

    private func runBatch() {
        batchRunning = true
        batchProgress = nil
        saveKey()
        let client = self.client
        let service = AITaggingService(database: env.database, cache: env.libraryModel.thumbnailCache)
        Task {
            defer { batchRunning = false }
            guard let ids = try? await service.untaggedItemIds(), !ids.isEmpty else {
                batchProgress = AITaggingService.Progress()
                return
            }
            _ = await service.tagItems(itemIds: ids, client: client) { progress in
                Task { @MainActor in
                    batchProgress = progress
                }
            }
        }
    }
}
