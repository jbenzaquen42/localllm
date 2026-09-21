//
//  MLXEngine.swift
//  LocalLLM
//
//  Native Apple-silicon inference for Hugging Face MLX checkpoints.
//  This is intentionally separate from llama.cpp and Swiftlet so their
//  existing download, validation, and inference paths remain unchanged.
//


import Combine
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@MainActor
final class MLXEngine: ObservableObject {
    static let shared = MLXEngine()

    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var currentModelId: String?
    @Published var loadError: String?
    @Published var downloadProgress: Double = 0

    @Published var tokensPerSecond: Double = 0
    @Published var timeToFirstToken: TimeInterval = 0
    @Published var totalTokens: Int = 0

    private var container: MLXLMCommon.ModelContainer?

    private init() {}

    func loadModel(
        _ model: AIModel,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async {
        guard model.engineFormat == .mlx else { return }
        guard currentModelId != model.id || !isModelLoaded else {
            progress?(1)
            return
        }

        isLoading = true
        loadError = nil
        downloadProgress = 0

        do {
            let configuration = ModelConfiguration(id: model.name)
            let downloader: any MLXLMCommon.Downloader = #hubDownloader()
            let tokenizerLoader: any MLXLMCommon.TokenizerLoader = #huggingFaceTokenizerLoader()
            let loaded: MLXLMCommon.ModelContainer = try await MLXLMCommon.loadModelContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration,
                progressHandler: { [weak self] (value: Progress) in
                    let fraction = value.fractionCompleted
                    Task { @MainActor in
                        self?.downloadProgress = fraction
                        progress?(fraction)
                    }
                }
            )
            container = loaded
            currentModelId = model.id
            isModelLoaded = true
            downloadProgress = 1
            progress?(1)
            print("[MLXEngine] loaded \(model.name)")
        } catch {
            container = nil
            currentModelId = nil
            isModelLoaded = false
            downloadProgress = 0
            loadError = "Couldn't load \(model.displayName): \(error.localizedDescription)"
            print("[MLXEngine] LOAD FAILED: \(error)")
        }

        isLoading = false
    }

    func unload() {
        container = nil
        currentModelId = nil
        isModelLoaded = false
        downloadProgress = 0
    }

    /// Rehydrates the visible conversation for each response. This keeps the
    /// app's saved-chat history authoritative when users switch conversations.
    func streamChat(messages: [[String: String]], maxTokens: Int) -> AsyncStream<String> {
        guard let container else { return AsyncStream { $0.finish() } }

        let system = messages.first(where: { $0["role"] == "system" })?["content"]
        let conversational = messages.filter { $0["role"] != "system" }
        guard let latest = conversational.last?["content"] else {
            return AsyncStream { $0.finish() }
        }

        let history: [MLXLMCommon.Chat.Message] = conversational.dropLast().compactMap { item in
            guard let content = item["content"] else { return nil }
            switch item["role"] {
            case "assistant": return .assistant(content)
            case "user": return .user(content)
            default: return nil
            }
        }

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.7,
            topP: 0.95,
            topK: 40
        )
        let session = MLXLMCommon.ChatSession(
            container,
            instructions: system,
            history: history,
            generateParameters: parameters
        )

        return AsyncStream { continuation in
            Task { @MainActor in
                let start = Date()
                var firstTokenAt: Date?
                var emittedText = ""

                do {
                    for try await delta in session.streamResponse(to: latest) {
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        emittedText += delta
                        continuation.yield(delta)
                    }
                } catch {
                    continuation.yield("\n[Generation error: \(error.localizedDescription)]")
                }

                // ChatSession streams text rather than exposing token ids. This
                // estimate is used only for the optional UI benchmark badge.
                let estimatedTokens = max(0, emittedText.count / 4)
                let generationStart = firstTokenAt ?? start
                let generationSeconds = max(0.001, -generationStart.timeIntervalSinceNow)
                totalTokens = estimatedTokens
                timeToFirstToken = firstTokenAt?.timeIntervalSince(start) ?? 0
                tokensPerSecond = Double(estimatedTokens) / generationSeconds
                continuation.finish()
            }
        }
    }
}
