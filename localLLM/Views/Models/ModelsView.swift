//
//  ModelsView.swift
//  LocalLLM
//

import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var huggingFaceService: HuggingFaceService
    @State private var selectedSegment = 0
    @State private var searchText = ""
    @State private var showImportSheet = false
    @State private var showRepositorySheet = false

    var filteredModels: [AIModel] {
        let models: [AIModel]
        switch selectedSegment {
        case 0: models = modelManager.availableModels
        case 1: models = huggingFaceService.remoteModels
        case 2: models = modelManager.downloadedModels
        default: models = []
        }

        if searchText.isEmpty {
            return models
        } else {
            return models.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
            ZStack {
                LinearGradient(
                    colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 20, pinnedViews: [.sectionHeaders]) {
                        Section {
                            if selectedSegment == 1 && huggingFaceService.isLoading {
                                VStack(spacing: 12) {
                                    ProgressView()
                                    Text("Fetching models from HuggingFace...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 40)
                            } else if selectedSegment == 1 && huggingFaceService.remoteModels.isEmpty && !huggingFaceService.isLoading {
                                VStack(spacing: 16) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                    Text("Tap to browse community models")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        Task { await huggingFaceService.fetchModels() }
                                    } label: {
                                        HStack {
                                            Image(systemName: "arrow.clockwise")
                                            Text("Load Models")
                                        }
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.blue)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                    }
                                }
                                .padding(.vertical, 40)
                            } else {
                                ForEach(filteredModels) { model in
                                    ModelCardView(model: model)
                                }
                                .padding(.horizontal)
                            }
                        } header: {
                            VStack(spacing: 0) {
                                Picker("Models", selection: $selectedSegment) {
                                    Text("Built-in").tag(0)
                                    Text("Community").tag(1)
                                    Text("Downloaded").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                    .padding(.top, 0)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showRepositorySheet = true
                        } label: {
                            Label("Add Hugging Face Model", systemImage: "link.badge.plus")
                        }
                        Button {
                            showImportSheet = true
                        } label: {
                            Label("Import GGUF File", systemImage: "doc.badge.plus")
                        }
                        if selectedSegment == 1 {
                            Button {
                                Task { await huggingFaceService.fetchModels() }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .sheet(isPresented: $showImportSheet) {
                ImportModelSheet()
            }
            .sheet(isPresented: $showRepositorySheet) {
                HuggingFaceRepositorySheet()
            }
            .overlay {
                if filteredModels.isEmpty && selectedSegment != 1 {
                    EmptyModelsListView(isDownloaded: selectedSegment == 2)
                }
            }
            .alert("Download Error", isPresented: Binding(
                get: { modelManager.downloadError != nil },
                set: { if !$0 { modelManager.downloadError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(modelManager.downloadError ?? "")
            }
            .navigationTitle("Models")
    }
}

// MARK: - Hugging Face repository import

struct HuggingFaceRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var huggingFaceService: HuggingFaceService

    @State private var repositoryURL = ""
    @State private var inspection: HuggingFaceRepositoryInspection?
    @State private var selectedOptionID: String?
    @State private var isInspecting = false
    @State private var errorMessage: String?
    @State private var installingModelID: String?

    private var selectedOption: HuggingFaceDownloadOption? {
        guard let selectedOptionID else { return nil }
        return inspection?.options.first { $0.id == selectedOptionID }
    }

    private var installingModel: AIModel? {
        guard let installingModelID else { return nil }
        return modelManager.availableModels.first { $0.id == installingModelID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hugging Face model page")
                            .font(.headline)
                        TextField("https://huggingface.co/owner/model", text: $repositoryURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.go)
                            .onSubmit { inspect() }

                        Button(action: inspect) {
                            HStack {
                                if isInspecting { ProgressView().controlSize(.small) }
                                Text(isInspecting ? "Checking repository…" : "Find compatible options")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInspecting || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let installingModel {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                Image(systemName: installingModel.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 34))
                                    .foregroundStyle(installingModel.isDownloaded ? .green : .blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(
                                        installingModel.isDownloaded
                                            ? "Model installed"
                                            : (installingModel.isDownloading ? "Download started" : "Download paused")
                                    )
                                        .font(.title3.bold())
                                    Text(installingModel.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !installingModel.isDownloaded {
                                ProgressView(value: installingModel.downloadProgress)
                                    .tint(.blue)
                                HStack {
                                    Text("\(Int(installingModel.downloadProgress * 100))%")
                                    Spacer()
                                    Text(installingModel.formattedSize)
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }

                            if let downloadError = modelManager.downloadError {
                                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }

                            Label(
                                installingModel.engineFormat == .gguf
                                    ? "This GGUF transfer continues while the screen is locked. Do not force-quit the app."
                                    : "Keep Priv AI open while this format downloads; interrupted installs can resume.",
                                systemImage: "lock.iphone"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                            if installingModel.isExperimentalLargeGGUF {
                                Label(
                                    "Experimental memory-mapped mode. This is not a Swiftlet QPack, so the 8 tok/s Swiftlet result is not a performance guarantee.",
                                    systemImage: "flask.fill"
                                )
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            }

                            HStack {
                                if !installingModel.isDownloaded && !installingModel.isDownloading {
                                    Button("Try Again") {
                                        modelManager.downloadModel(installingModel)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button(installingModel.isDownloaded ? "Done" : "Continue in Models") {
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if let inspection {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(inspection.displayName)
                                .font(.title3.bold())
                            Text(inspection.repoID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Text("Choose format or quantization")
                            .font(.headline)

                        VStack(spacing: 10) {
                            ForEach(inspection.options) { option in
                                Button {
                                    selectedOptionID = option.id
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedOptionID == option.id
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedOptionID == option.id ? .blue : .secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(option.title).font(.subheadline.bold())
                                                Text(option.kind.rawValue.uppercased())
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color.blue.opacity(0.12))
                                                    .clipShape(Capsule())
                                                if option.isRecommended {
                                                    Text("RECOMMENDED")
                                                        .font(.caption2.bold())
                                                        .foregroundStyle(.green)
                                                }
                                            }
                                            Text(option.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text(option.formattedSize)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(12)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedOptionID == option.id ? Color.blue : Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if inspection.hasShardedGGUF {
                            Label("Split GGUF files are shown only when a single-file alternative is available.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            guard let option = selectedOption,
                                  let model = huggingFaceService.model(from: option, repository: inspection) else { return }
                            modelManager.addAndDownloadRemoteModel(model)
                            installingModelID = model.id
                        } label: {
                            Label("Add and Download", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedOption == nil)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Add Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func inspect() {
        isInspecting = true
        inspection = nil
        selectedOptionID = nil
        errorMessage = nil
        Task {
            do {
                let result = try await huggingFaceService.inspectRepository(repositoryURL)
                inspection = result
                selectedOptionID = result.requestedFilePath.flatMap { requestedPath in
                    result.options.first { $0.filePath == requestedPath }?.id
                } ?? result.options.first(where: { $0.isRecommended })?.id ?? result.options.first?.id
            } catch {
                errorMessage = error.localizedDescription
            }
            isInspecting = false
        }
    }
}

struct ModelCardView: View {
    let model: AIModel
    @EnvironmentObject var modelManager: ModelManager
    @State private var showDeleteAlert = false

    // Read live state from modelManager so progress updates show
    private var liveModel: AIModel {
        modelManager.availableModels.first(where: { $0.id == model.id }) ?? model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        Text(model.formattedSize)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        CompatibilityBadge(model: model)

                        if liveModel.isDownloaded {
                            Text("INSTALLED")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                }

                Spacer()

                if liveModel.isDownloading {
                    VStack(spacing: 4) {
                        ProgressView(value: liveModel.downloadProgress)
                            .progressViewStyle(.circular)
                            .frame(width: 24, height: 24)
                        Text("\(Int(liveModel.downloadProgress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Description
            Text(model.description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .opacity(0.5)

            // Actions
            // Download progress bar
            if liveModel.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: liveModel.downloadProgress)
                        .tint(.blue)
                    HStack {
                        Text("Downloading... \(Int(liveModel.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            modelManager.cancelDownload(model)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    }
                }
            }

            HStack(spacing: 12) {
                if liveModel.isDownloading {
                    EmptyView() // Progress bar shown above
                } else if !liveModel.isDownloaded {
                    DownloadButton(model: model)
                } else {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.05))
                            .foregroundColor(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let huggingFaceUrl = model.huggingFaceUrl,
                   let url = URL(string: huggingFaceUrl) {
                    Link(destination: url) {
                        Image(systemName: "safari")
                            .font(.system(size: 16))
                            .frame(width: 40, height: 40)
                            .background(Color(uiColor: .secondarySystemFill))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        .alert("Delete Model", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                modelManager.deleteModel(model)
            }
        } message: {
            Text("Are you sure you want to delete \(model.displayName)? This action cannot be undone.")
        }
    }
}

struct EmptyModelsListView: View {
    let isDownloaded: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isDownloaded ? "cube.box" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(spacing: 8) {
                Text(isDownloaded ? "No Downloaded Models" : "No Models Found")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)

                Text(isDownloaded ?
                     "Models you download will appear here" :
                     "Try adjusting your search")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

// MARK: - Download Button (resolves community URLs before downloading)

struct DownloadButton: View {
    let model: AIModel
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var huggingFaceService: HuggingFaceService
    @State private var isResolving = false

    var body: some View {
        Button {
            print("[ModelsView] Download tapped for: \(model.displayName)")
            startDownload()
        } label: {
            HStack {
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                }
                Text(isResolving ? "Preparing..." : "Download")
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
    }

    private func startDownload() {
        if model.modelUrl.isEmpty {
            // Community model - need to resolve URL first
            isResolving = true
            Task {
                if let resolved = await huggingFaceService.resolveDownloadURL(for: model) {
                    if !modelManager.availableModels.contains(where: { $0.id == resolved.id }) {
                        modelManager.availableModels.append(resolved)
                    }
                    modelManager.downloadModel(resolved)
                } else {
                    modelManager.downloadError = "Could not find a suitable GGUF file for this model."
                }
                isResolving = false
            }
        } else {
            // Built-in model - URL already known
            if !modelManager.availableModels.contains(where: { $0.id == model.id }) {
                modelManager.availableModels.append(model)
            }
            modelManager.downloadModel(model)
        }
    }
}

// MARK: - Compatibility Badge

struct CompatibilityBadge: View {
    @EnvironmentObject var inferenceManager: InferenceManager
    let model: AIModel
    @State private var showInfo = false

    private var report: InferenceManager.CompatibilityReport {
        inferenceManager.compatibility(for: model)
    }

    private var dotColor: Color {
        switch report.status {
        case .green:  return .green
        case .yellow: return .orange
        case .red:    return .red
        }
    }

    var body: some View {
        Button {
            showInfo = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(report.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo, arrowEdge: .top) {
            CompatibilityInfoPopover(report: report)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct CompatibilityInfoPopover: View {
    let report: InferenceManager.CompatibilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How this is calculated")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                CompatibilityInfoRow(label: "Model size", value: "\(report.modelSizeMB) MB")
                if report.isEstimateUnavailable {
                    CompatibilityInfoRow(label: "Load mode", value: "Memory mapped")
                    CompatibilityInfoRow(label: "Working memory", value: "Measure on device", bold: true)
                } else {
                    CompatibilityInfoRow(label: "Inference overhead", value: "+\(report.inferenceOverheadMB) MB")
                    Divider()
                    CompatibilityInfoRow(label: "Total needed", value: "\(report.requiredMB) MB", bold: true)
                    CompatibilityInfoRow(label: "iOS gives this app", value: "\(report.deviceBudgetMB) MB")
                    CompatibilityInfoRow(label: "Usage", value: "\(report.percentOfBudget)% of budget", bold: true)
                }
            }
            .font(.system(size: 13))

            Divider()

            Text(report.reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Inference overhead covers KV cache and compute buffers (roughly half the model size). iOS sets a per-app memory budget independent of how much total RAM your phone has, so closing other apps will not raise it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct CompatibilityInfoRow: View {
    let label: String
    let value: String
    var bold: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

#Preview {
    ModelsView()
        .environmentObject(ModelManager())
        .environmentObject(HuggingFaceService())
}
