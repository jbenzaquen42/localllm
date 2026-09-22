//
//  ModelManager.swift
//  LocalLLM
//

import Foundation
import SwiftletCore
import Combine

enum ModelImportError: LocalizedError {
    case accessDenied
    case invalidGGUF

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Priv AI could not access that Files item. Download it to On My iPhone and try again."
        case .invalidGGUF:
            return "The selected file is not a valid GGUF model."
        }
    }
}

class ModelManager: NSObject, ObservableObject {
    @Published var availableModels: [AIModel] = []
    @Published var downloadedModels: [AIModel] = []
    @Published var isLoadingAllowlist = false
    @Published var tasks: [AITask] = AITask.sampleTasks
    @Published var downloadError: String?
    /// A non-error status for the model installer. This is intentionally
    /// separate from `downloadError`: starting a background URLSession task
    /// should produce visible confirmation even when there is no error.
    @Published var downloadStatus: String?
    @Published private(set) var storageLocation: ModelStorageLocation

    /// User's preferred default model id, persisted to UserDefaults.
    /// Set whenever the user actively picks a model. Falls back to first downloaded if missing or deleted.
    @Published var preferredModelId: String? {
        didSet {
            if let id = preferredModelId {
                UserDefaults.standard.set(id, forKey: Self.preferredModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredModelKey)
            }
        }
    }

    private static let preferredModelKey = "preferred_model_id"

    /// The model the app should default to: user's preferred (if downloaded) else first downloaded else first sample.
    var defaultModel: AIModel {
        if let id = preferredModelId, let m = downloadedModels.first(where: { $0.id == id }) {
            return m
        }
        return downloadedModels.first ?? AIModel.sampleModels[0]
    }

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var mlxDownloadTasks: [String: Task<Void, Never>] = [:]

    /// A background session hands GGUF transfers to iOS so they continue when
    /// Priv AI is suspended or the screen locks.
    private lazy var backgroundDownloadSession: URLSession = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jbenzaquen42.PrivAI"
        let config = URLSessionConfiguration.background(withIdentifier: "\(bundleID).model-downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    override init() {
        // Restore the user's preferred model id (if set previously)
        self.preferredModelId = UserDefaults.standard.string(forKey: Self.preferredModelKey)
        self.storageLocation = ModelStorage.current
        super.init()
        ensureModelsDirectory()
        loadModelAllowlist()
        reconnectBackgroundDownloads()
    }

    // MARK: - Directory Management

    static var modelsDirectory: URL {
        ModelStorage.modelsDirectory(for: ModelStorage.current)
    }

    private func ensureModelsDirectory(at location: ModelStorageLocation = ModelStorage.current) {
        var dir = ModelStorage.modelsDirectory(for: location)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// Moves GGUF and Swiftlet files between the Files-visible and private
    /// app-owned locations. MLX keeps using its managed Hugging Face cache.
    @discardableResult
    func changeStorageLocation(to newLocation: ModelStorageLocation) -> Bool {
        guard newLocation != storageLocation else { return true }
        guard !availableModels.contains(where: { $0.isDownloading }) else {
            downloadError = "Wait for active model downloads to finish before changing storage."
            return false
        }

        let oldLocation = storageLocation
        let source = ModelStorage.modelsDirectory(for: oldLocation)
        let destination = ModelStorage.modelsDirectory(for: newLocation)
        ensureModelsDirectory(at: newLocation)
        var moved: [(from: URL, to: URL)] = []

        do {
            guard FileManager.default.fileExists(atPath: source.path) else {
                ModelStorage.current = newLocation
                storageLocation = newLocation
                loadModelAllowlist()
                return true
            }
            let items = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            )
            for item in items {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: item, to: target)
                moved.append((from: item, to: target))
            }

            ModelStorage.current = newLocation
            storageLocation = newLocation
            loadModelAllowlist()
            return true
        } catch {
            for pair in moved.reversed() where FileManager.default.fileExists(atPath: pair.to.path) {
                try? FileManager.default.moveItem(at: pair.to, to: pair.from)
            }
            downloadError = "Could not move model files: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Load Models

    func loadModelAllowlist() {
        isLoadingAllowlist = true

        var models = AIModel.sampleModels

        // Load any custom imported models from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "custom_models"),
           let customModels = try? JSONDecoder().decode([AIModel].self, from: data) {
            print("[ModelManager] Loaded \(customModels.count) custom models from UserDefaults")
            models.append(contentsOf: customModels)
        }

        // Log the Models directory contents
        let modelsDir = Self.modelsDirectory
        print("[ModelManager] Models directory: \(modelsDir.path)")
        if let contents = try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            print("[ModelManager] Files on disk (\(contents.count)):")
            for file in contents {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                print("  - \(file.lastPathComponent): \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
        } else {
            print("[ModelManager] Models directory is empty or doesn't exist")
        }

        // Check which models are actually downloaded on disk
        for i in 0..<models.count {
            let localPath = models[i].localPath
            var exists = FileManager.default.fileExists(atPath: localPath.path)
            // Container models: the folder appears the moment a download
            // starts. Only count it downloaded when the manifest exists —
            // the installer writes it last, after every byte is in place.
            if exists, models[i].engineFormat == .swiftlet {
                exists = FileManager.default.fileExists(
                    atPath: localPath.appendingPathComponent("manifest.json").path)
            }
            if exists, models[i].engineFormat == .mlx {
                exists = Self.isCompleteMLXRepository(at: localPath)
            }
            models[i].isDownloaded = exists
            models[i].downloadProgress = exists ? 1.0 : 0.0
            if exists {
                print("[ModelManager] \(models[i].displayName) -> FOUND at \(localPath.path)")
            }
        }

        self.availableModels = models
        self.downloadedModels = models.filter { $0.isDownloaded }
        print("[ModelManager] Total: \(models.count) available, \(downloadedModels.count) downloaded")
        self.isLoadingAllowlist = false
        self.updateTaskModels()
    }

    private func updateTaskModels() {
        for i in 0..<tasks.count {
            let taskId = tasks[i].id
            let modelsForTask = availableModels.filter { model in
                model.taskIds.contains(taskId)
            }
            tasks[i].models = modelsForTask
        }
    }

    // MARK: - Download

    @discardableResult
    func downloadModel(_ model: AIModel) -> Bool {
        guard let index = availableModels.firstIndex(where: { $0.id == model.id }) else {
            downloadError = "Could not start \(model.displayName): the model was not registered."
            return false
        }
        guard !availableModels[index].isDownloading else {
            downloadStatus = "Download already running for \(model.displayName)."
            return true
        }
        downloadStatus = nil
        downloadError = nil

        // Streamed (Swiftlet) models install via the streaming installer:
        // bytes route from Hugging Face straight into the on-device container,
        // resumable if interrupted (tap Download again to continue).
        if model.engineFormat == .swiftlet {
            return downloadSwiftletModel(model, at: index)
        }
        if model.engineFormat == .mlx {
            return downloadMLXModel(model, at: index)
        }

        // Check available disk space
        let requiredSpace = model.modelSize
        if let availableSpace = availableDiskSpace(), availableSpace < requiredSpace + 500_000_000 {
            let needed = ByteCountFormatter.string(fromByteCount: requiredSpace + 500_000_000, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
            downloadError = "Not enough storage. Need \(needed), have \(available)."
            return false
        }

        guard !model.modelUrl.isEmpty,
              let url = URL(string: model.modelUrl),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            downloadError = "Could not start \(model.displayName): the download URL is invalid."
            return false
        }

        availableModels[index].isDownloading = true
        availableModels[index].downloadProgress = 0

        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = true

        let downloadTask = backgroundDownloadSession.downloadTask(with: request)
        downloadTask.taskDescription = model.id

        downloadTasks[model.id] = downloadTask
        downloadTask.resume()
        downloadStatus = "Download started for \(model.displayName) (\(model.formattedSize))."
        return true
    }

    private func reconnectBackgroundDownloads() {
        backgroundDownloadSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for case let task as URLSessionDownloadTask in tasks {
                    guard let modelID = task.taskDescription,
                          let index = self.availableModels.firstIndex(where: { $0.id == modelID }) else { continue }
                    self.downloadTasks[modelID] = task
                    self.availableModels[index].isDownloading = true
                    if task.countOfBytesExpectedToReceive > 0 {
                        self.availableModels[index].downloadProgress = Double(task.countOfBytesReceived)
                            / Double(task.countOfBytesExpectedToReceive)
                    }
                }
            }
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Streaming install for directory-container models. Progress comes from
    /// the installer's own byte accounting; re-invoking resumes.
    @discardableResult
    private func downloadSwiftletModel(_ model: AIModel, at index: Int) -> Bool {
        // HF repos rate-limit anonymous downloads; any other host (e.g. an
        // R2/CDN mirror) is fetched directly at full speed.
        let source: StreamingInstaller.Source
        if model.modelUrl.contains("huggingface.co/"),
           let repo = model.modelUrl.components(separatedBy: "huggingface.co/").last, !repo.isEmpty {
            source = .huggingFace(repo: repo)
        } else if model.modelUrl.hasPrefix("http") {
            source = .baseURL(model.modelUrl)
        } else {
            downloadError = "Invalid model source."
            return false
        }
        if let availableSpace = availableDiskSpace(), availableSpace < model.modelSize + 2_000_000_000 {
            downloadError = "Not enough free space: this model needs about \(ByteCountFormatter.string(fromByteCount: model.modelSize, countStyle: .file)) plus headroom."
            return false
        }
        downloadError = nil
        availableModels[index].isDownloading = true
        availableModels[index].downloadProgress = 0

        let cancelFlag = CancelFlag()
        swiftletCancelFlags[model.id] = cancelFlag
        let expectedBytes = Double(model.modelSize)
        let dest = model.localPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let installer = StreamingInstaller(
                source: source,
                outputDir: dest
            )
            installer.shouldCancel = { cancelFlag.isSet }
            // Smooth progress: resumed bytes already on disk + bytes this run.
            let startingBytes = Double(Self.directorySize(dest))
            installer.onBytes = { newBytes in
                DispatchQueue.main.async {
                    guard let self, let i = self.availableModels.firstIndex(where: { $0.id == model.id }) else { return }
                    self.availableModels[i].downloadProgress = min(0.99, (startingBytes + Double(newBytes)) / expectedBytes)
                }
            }
            installer.log = { print("[SwiftletInstall] \($0)") }
            do {
                try installer.install()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.swiftletCancelFlags.removeValue(forKey: model.id)
                    if let i = self.availableModels.firstIndex(where: { $0.id == model.id }) {
                        self.availableModels[i].isDownloading = false
                        self.availableModels[i].downloadProgress = 1.0
                        self.availableModels[i].isDownloaded = true
                    }
                    self.downloadedModels.append(model)
                    self.updateTaskModels()
                    self.saveCustomModels()
                    self.downloadStatus = "Download complete for \(model.displayName)."
                    print("[ModelManager] streamed install complete: \(model.id)")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.swiftletCancelFlags.removeValue(forKey: model.id)
                    if let i = self.availableModels.firstIndex(where: { $0.id == model.id }) {
                        self.availableModels[i].isDownloading = false
                    }
                    if case StreamingInstaller.Error.cancelled = error {
                        print("[ModelManager] streamed install cancelled: \(model.id)")
                    } else {
                        self.downloadStatus = nil
                        self.downloadError = "Download interrupted (\(error.localizedDescription)). Tap Download again to resume; progress is kept."
                    }
                }
            }
        }
        downloadStatus = "Download started for \(model.displayName). Keep Priv AI open while this package is prepared."
        return true
    }

    /// Thread-safe cancellation flag polled by the streaming installer.
    private final class CancelFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
    }
    private var swiftletCancelFlags: [String: CancelFlag] = [:]

    @discardableResult
    private func downloadMLXModel(_ model: AIModel, at index: Int) -> Bool {
        if let availableSpace = availableDiskSpace(), availableSpace < model.modelSize + 1_000_000_000 {
            downloadError = "Not enough free space: this MLX model needs about \(model.formattedSize) plus headroom."
            return false
        }

        downloadError = nil
        availableModels[index].isDownloading = true
        availableModels[index].downloadProgress = 0

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await MLXEngine.shared.loadModel(model) { fraction in
                guard let i = self.availableModels.firstIndex(where: { $0.id == model.id }) else { return }
                self.availableModels[i].downloadProgress = min(1, max(0, fraction))
            }

            self.mlxDownloadTasks.removeValue(forKey: model.id)
            guard let i = self.availableModels.firstIndex(where: { $0.id == model.id }) else { return }
            self.availableModels[i].isDownloading = false

            if MLXEngine.shared.currentModelId == model.id, MLXEngine.shared.isModelLoaded {
                self.availableModels[i].downloadProgress = 1
                self.availableModels[i].isDownloaded = true
                if !self.downloadedModels.contains(where: { $0.id == model.id }) {
                    self.downloadedModels.append(self.availableModels[i])
                }
                self.updateTaskModels()
                self.saveCustomModels()
                self.downloadStatus = "Download complete for \(model.displayName)."
            } else if !Task.isCancelled {
                self.availableModels[i].downloadProgress = 0
                self.downloadStatus = nil
                self.downloadError = MLXEngine.shared.loadError ?? "MLX model download failed."
            }
        }
        mlxDownloadTasks[model.id] = task
        downloadStatus = "Download started for \(model.displayName). Keep Priv AI open while this format downloads."
        return true
    }

    private static func isCompleteMLXRepository(at repository: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: repository,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        var hasConfig = false
        var hasWeights = false
        for case let file as URL in enumerator {
            let name = file.lastPathComponent.lowercased()
            if name == "config.json" { hasConfig = true }
            if name.hasSuffix(".safetensors") { hasWeights = true }
            if hasConfig && hasWeights { return true }
        }
        return false
    }

    /// First downloaded model that can serve Health/Finance/Journal features.
    /// The experimental streamed 35B is chat-only, so it never qualifies.
    var firstAssistCapableModel: AIModel? {
        downloadedModels.first {
            $0.taskIds.contains(BuiltInTaskID.llmHealth.rawValue)
                || $0.taskIds.contains(BuiltInTaskID.llmFinance.rawValue)
        }
    }

    /// True when models are installed but every one of them is chat-only —
    /// the state where assist features should say "download another model".
    var onlyChatOnlyModelsInstalled: Bool {
        firstAssistCapableModel == nil && !downloadedModels.isEmpty
    }

    func cancelDownload(_ model: AIModel) {
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)
        swiftletCancelFlags[model.id]?.set()
        mlxDownloadTasks[model.id]?.cancel()
        mlxDownloadTasks.removeValue(forKey: model.id)

        if let index = availableModels.firstIndex(where: { $0.id == model.id }) {
            availableModels[index].isDownloading = false
            availableModels[index].downloadProgress = 0
        }
    }

    // MARK: - Delete

    func deleteModel(_ model: AIModel) {
        let localPath = model.localPath
        print("[ModelManager] Deleting \(model.displayName) at \(localPath.path)")

        // A loaded Swiftlet session mmaps files inside this directory —
        // unload before removing so the engine can't serve a deleted model.
        if model.engineFormat == .swiftlet {
            Task { @MainActor in
                if SwiftletEngine.shared.currentModelId == model.id {
                    SwiftletEngine.shared.unload()
                }
            }
        }
        if model.engineFormat == .mlx {
            Task { @MainActor in
                if MLXEngine.shared.currentModelId == model.id {
                    MLXEngine.shared.unload()
                }
            }
        }

        do {
            if FileManager.default.fileExists(atPath: localPath.path) {
                try FileManager.default.removeItem(at: localPath)
                print("[ModelManager] Successfully deleted \(model.displayName)")
            } else {
                print("[ModelManager] File not found at \(localPath.path) - marking as not downloaded")
            }
        } catch {
            print("[ModelManager] Delete error: \(error)")
            downloadError = "Failed to delete: \(error.localizedDescription)"
        }

        if let index = availableModels.firstIndex(where: { $0.id == model.id }) {
            availableModels[index].isDownloaded = false
            availableModels[index].downloadProgress = 0
        }

        downloadedModels.removeAll { $0.id == model.id }

        // If the deleted model was the user's preferred default, clear it so we fall back to the next available.
        if preferredModelId == model.id {
            preferredModelId = nil
        }

        updateTaskModels()
    }

    // MARK: - Import

    @MainActor
    func importModel(from url: URL, name: String, displayName: String) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw ModelImportError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let modelId = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let destination = Self.modelsDirectory.appendingPathComponent("\(modelId).gguf")
        let staged = Self.modelsDirectory.appendingPathComponent(".importing-\(UUID().uuidString).gguf")

        let fileSize = try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: url, to: staged)
            guard Self.isValidGGUF(at: staged) else { throw ModelImportError.invalidGGUF }
            let values = try staged.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            return size
        }.value

        var newModel = AIModel(
            id: modelId,
            name: name,
            displayName: displayName,
            description: "Imported GGUF model",
            modelUrl: "",
            modelSize: fileSize,
            taskIds: [BuiltInTaskID.llmChat.rawValue],
            huggingFaceUrl: nil,
            parameters: AIModel.ModelParameters(
                temperature: 0.7, topK: 40, topP: 0.95, maxTokens: 1024, randomSeed: 42
            ),
            chatTemplate: .chatml
        )
        newModel.isDownloaded = true
        newModel.downloadProgress = 1.0

        if let index = availableModels.firstIndex(where: { $0.id == modelId }) {
            availableModels[index] = newModel
        } else {
            availableModels.append(newModel)
        }
        if let index = downloadedModels.firstIndex(where: { $0.id == modelId }) {
            downloadedModels[index] = newModel
        } else {
            downloadedModels.append(newModel)
        }
        updateTaskModels()
        saveCustomModels()
    }

    /// Registers a model discovered from a pasted Hugging Face repository and
    /// starts it through the normal download path.
    @discardableResult
    func addAndDownloadRemoteModel(_ model: AIModel) -> Bool {
        if let index = availableModels.firstIndex(where: { $0.id == model.id }) {
            availableModels[index] = model
        } else {
            availableModels.append(model)
        }
        updateTaskModels()
        saveCustomModels()
        return downloadModel(model)
    }

    // MARK: - Storage

    func calculateCacheSize() -> Int64 {
        let dir = Self.modelsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for file in contents {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func clearCache() {
        let dir = Self.modelsDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }
        loadModelAllowlist()
    }

    func formattedCacheSize() -> String {
        let size = calculateCacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    func availableDiskSpace() -> Int64? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.first else { return nil }
        guard let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    private func saveCustomModels() {
        let sampleIds = Set(AIModel.sampleModels.map { $0.id })
        let customModels = availableModels.filter { !sampleIds.contains($0.id) }
        if let data = try? JSONEncoder().encode(customModels) {
            UserDefaults.standard.set(data, forKey: "custom_models")
        }
    }

}

// MARK: - URLSessionDownloadDelegate

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let modelId = downloadTask.taskDescription else { return }
        guard let index = availableModels.firstIndex(where: { $0.id == modelId }) else { return }

        let destination = availableModels[index].localPath

        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            availableModels[index].isDownloading = false
            availableModels[index].downloadProgress = 0
            downloadStatus = nil
            downloadError = "Download failed (HTTP \(response.statusCode)). Check that the Hugging Face file link is public and points to a single GGUF file."
            try? FileManager.default.removeItem(at: location)
            downloadTasks.removeValue(forKey: modelId)
            return
        }

        // Validate GGUF magic bytes before accepting the file
        if !Self.isValidGGUF(at: location) {
            availableModels[index].isDownloading = false
            availableModels[index].downloadProgress = 0
            downloadStatus = nil
            downloadError = "Download corrupted (invalid GGUF file). Please try again."
            try? FileManager.default.removeItem(at: location)
            downloadTasks.removeValue(forKey: modelId)
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            availableModels[index].isDownloading = false
            availableModels[index].isDownloaded = true
            availableModels[index].downloadProgress = 1.0
            if let downloadedIndex = downloadedModels.firstIndex(where: { $0.id == modelId }) {
                downloadedModels[downloadedIndex] = availableModels[index]
            } else {
                downloadedModels.append(availableModels[index])
            }
            updateTaskModels()
            saveCustomModels()
            downloadStatus = "Download complete for \(availableModels[index].displayName)."
        } catch {
            availableModels[index].isDownloading = false
            availableModels[index].downloadProgress = 0
            downloadError = "Failed to save model: \(error.localizedDescription)"
            downloadStatus = nil
            try? FileManager.default.removeItem(at: location) // Clean up temp file
        }

        downloadTasks.removeValue(forKey: modelId)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let modelId = downloadTask.taskDescription else { return }
        guard let index = availableModels.firstIndex(where: { $0.id == modelId }) else { return }

        if totalBytesExpectedToWrite > 0 {
            let newProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            // Only update UI when progress changes by >1% to reduce re-renders
            if abs(newProgress - availableModels[index].downloadProgress) > 0.01 {
                availableModels[index].downloadProgress = newProgress
            }
        }

        // Periodically check disk space during download (every ~50MB)
        if totalBytesWritten % (50 * 1024 * 1024) < bytesWritten {
            if let available = availableDiskSpace(), available < 200_000_000 {
                downloadTask.cancel()
                availableModels[index].isDownloading = false
                availableModels[index].downloadProgress = 0
                downloadStatus = nil
                downloadError = "Disk space too low. Download cancelled to prevent storage issues."
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let modelId = task.taskDescription else { return }

        if let error = error as? NSError, error.code != NSURLErrorCancelled {
            downloadError = "Download failed (\(error.domain) \(error.code)): \(error.localizedDescription)"
            downloadStatus = nil
            if let index = availableModels.firstIndex(where: { $0.id == modelId }) {
                availableModels[index].isDownloading = false
                availableModels[index].downloadProgress = 0
                // Clean up any partial file on failure
                let path = availableModels[index].localPath
                if FileManager.default.fileExists(atPath: path.path) {
                    try? FileManager.default.removeItem(at: path)
                }
            }
        }

        downloadTasks.removeValue(forKey: modelId)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundDownloadBridge.finishEvents()
    }

    /// Validate GGUF magic bytes (0x47475546 = "GGUF")
    static func isValidGGUF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data[0] == 0x47 && data[1] == 0x47 && data[2] == 0x55 && data[3] == 0x46
    }
}
