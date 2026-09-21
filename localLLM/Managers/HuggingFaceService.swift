//
//  HuggingFaceService.swift
//  LocalLLM
//
//  Fetches available GGUF models from the HuggingFace API.
//

import Foundation
import Combine

struct HuggingFaceDownloadOption: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case gguf
        case swiftlet
        case mlx
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let filePath: String?
    let size: Int64
    let isRecommended: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct HuggingFaceRepositoryInspection {
    let repoID: String
    let displayName: String
    let options: [HuggingFaceDownloadOption]
    let hasRawMLXCheckpoint: Bool
    let hasShardedGGUF: Bool

    var modelPageURL: String { "https://huggingface.co/\(repoID)" }
}

enum HuggingFaceRepositoryError: LocalizedError {
    case invalidRepository
    case requestFailed(Int)
    case noCompatibleFiles

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Enter a Hugging Face model page such as https://huggingface.co/owner/model."
        case .requestFailed(let status):
            return status == 401 || status == 403
                ? "This repository is private or gated. Sign-in tokens are not supported yet."
                : "Hugging Face returned HTTP \(status)."
        case .noCompatibleFiles:
            return "This repository does not contain a compatible GGUF, MLX, or Swiftlet QPack model."
        }
    }
}

@MainActor
class HuggingFaceService: ObservableObject {
    @Published var remoteModels: [AIModel] = []
    @Published var isLoading = false
    @Published var error: String?

    private static let templateMap: [String: ChatTemplate] = [
        "llama": .llama3, "gemma": .gemma, "phi": .phi3,
        "qwen": .chatml, "smol": .chatml, "mistral": .chatml,
        "tinyllama": .chatml, "stable": .chatml, "deepseek": .chatml,
        "yi": .chatml, "openchat": .chatml, "zephyr": .chatml,
        "neural": .chatml, "rocket": .chatml,
    ]

    private struct RepositoryResponse: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }

        let modelId: String?
        let siblings: [Sibling]
        let tags: [String]?
    }

    /// Accepts either `owner/repository` or a normal Hugging Face model-page URL.
    static func repositoryID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let url = URL(string: candidate),
           let host = url.host?.lowercased(),
           host == "huggingface.co" || host == "www.huggingface.co" {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 2 else { return nil }
            return "\(components[0])/\(components[1])"
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else { return nil }
        return "\(components[0])/\(components[1])"
    }

    /// Inspects one repository and returns only options the current app can run.
    /// MLX checkpoints are represented as a single repository option because
    /// MLX Swift LM downloads the config, tokenizer, and weight shards together.
    func inspectRepository(_ input: String) async throws -> HuggingFaceRepositoryInspection {
        guard let repoID = Self.repositoryID(from: input),
              let escapedRepo = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/api/models/\(escapedRepo)?blobs=true") else {
            throw HuggingFaceRepositoryError.invalidRepository
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("PrivAI/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw HuggingFaceRepositoryError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let repository = try JSONDecoder().decode(RepositoryResponse.self, from: data)
        let resolvedRepoID = repository.modelId ?? repoID
        let tags = Set((repository.tags ?? []).map { $0.lowercased() })

        let allGGUF = repository.siblings.filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
        let splitPattern = try! NSRegularExpression(pattern: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.caseInsensitive])
        let singleFileGGUF = allGGUF.filter { sibling in
            let range = NSRange(sibling.rfilename.startIndex..., in: sibling.rfilename)
            return splitPattern.firstMatch(in: sibling.rfilename, range: range) == nil
        }

        let sortedGGUF = singleFileGGUF.sorted { lhs, rhs in
            let left = recommendationRank(for: lhs.rfilename)
            let right = recommendationRank(for: rhs.rfilename)
            if left != right { return left < right }
            return (lhs.size ?? 0) < (rhs.size ?? 0)
        }

        var options = sortedGGUF.map { sibling in
            let quant = quantizationLabel(from: sibling.rfilename)
            return HuggingFaceDownloadOption(
                id: "gguf:\(sibling.rfilename)",
                kind: .gguf,
                title: quant ?? sibling.rfilename,
                subtitle: sibling.rfilename,
                filePath: sibling.rfilename,
                size: sibling.size ?? 0,
                isRecommended: recommendationRank(for: sibling.rfilename) == 0
            )
        }

        let fileNames = Set(repository.siblings.map { $0.rfilename.lowercased() })
        let isQPack = fileNames.contains("manifest.json") && (tags.contains("qpack") || tags.contains("swiftlet"))
        if isQPack {
            let totalSize = repository.siblings.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            options.insert(
                HuggingFaceDownloadOption(
                    id: "swiftlet:\(resolvedRepoID)",
                    kind: .swiftlet,
                    title: "Swiftlet QPack",
                    subtitle: "Storage-streamed MoE package",
                    filePath: nil,
                    size: totalSize,
                    isRecommended: true
                ),
                at: 0
            )
        }

        let hasSafetensors = repository.siblings.contains { $0.rfilename.lowercased().hasSuffix(".safetensors") }
        let hasRawMLX = tags.contains("mlx") && hasSafetensors && !isQPack
        if hasRawMLX {
            let relevantFiles = repository.siblings.filter { sibling in
                let path = sibling.rfilename.lowercased()
                return path.hasSuffix(".safetensors")
                    || path.hasSuffix(".json")
                    || path.hasSuffix(".model")
                    || path.hasSuffix(".tiktoken")
            }
            let totalSize = relevantFiles.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let quant = repository.tags?
                .first(where: { $0.range(of: #"^\d+-bit$"#, options: .regularExpression) != nil })
                ?? "MLX"
            options.insert(
                HuggingFaceDownloadOption(
                    id: "mlx:\(resolvedRepoID)",
                    kind: .mlx,
                    title: quant.uppercased(),
                    subtitle: "Native MLX checkpoint",
                    filePath: nil,
                    size: totalSize,
                    isRecommended: true
                ),
                at: 0
            )
        }
        guard !options.isEmpty || hasRawMLX || !allGGUF.isEmpty else {
            throw HuggingFaceRepositoryError.noCompatibleFiles
        }

        return HuggingFaceRepositoryInspection(
            repoID: resolvedRepoID,
            displayName: resolvedRepoID.split(separator: "/").last.map(String.init) ?? resolvedRepoID,
            options: options,
            hasRawMLXCheckpoint: hasRawMLX,
            hasShardedGGUF: allGGUF.count != singleFileGGUF.count
        )
    }

    func model(
        from option: HuggingFaceDownloadOption,
        repository: HuggingFaceRepositoryInspection
    ) -> AIModel? {
        let modelURL: String
        let format: ModelFormat
        let tasks: [String]

        switch option.kind {
        case .gguf:
            guard let filePath = option.filePath,
                  let escapedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            modelURL = "https://huggingface.co/\(repository.repoID)/resolve/main/\(escapedPath)"
            format = .gguf
            tasks = [
                BuiltInTaskID.llmChat.rawValue,
                BuiltInTaskID.llmFinance.rawValue,
                BuiltInTaskID.llmHealth.rawValue,
            ]
        case .swiftlet:
            modelURL = repository.modelPageURL
            format = .swiftlet
            tasks = [BuiltInTaskID.llmChat.rawValue]
        case .mlx:
            modelURL = repository.modelPageURL
            format = .mlx
            tasks = [BuiltInTaskID.llmChat.rawValue]
        }

        let optionName: String
        switch option.kind {
        case .gguf: optionName = option.title
        case .swiftlet: optionName = "QPack"
        case .mlx: optionName = option.title
        }
        let displayName = "\(repository.displayName) · \(optionName)"
        let rawID = "\(repository.repoID)-\(option.id)".lowercased()
        let modelID = rawID
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return AIModel(
            id: modelID,
            name: repository.repoID,
            displayName: displayName,
            description: {
                switch option.kind {
                case .gguf: return "\(option.title) GGUF from \(repository.repoID)."
                case .swiftlet: return "Swiftlet QPack from \(repository.repoID). Experts stream from storage."
                case .mlx: return "Native MLX model from \(repository.repoID). Runs with MLX Swift LM."
                }
            }(),
            modelUrl: modelURL,
            modelSize: option.size,
            taskIds: tasks,
            huggingFaceUrl: repository.modelPageURL,
            parameters: AIModel.ModelParameters(
                temperature: 0.7, topK: 40, topP: 0.95, maxTokens: 1024, randomSeed: 42
            ),
            chatTemplate: guessTemplate(from: repository.repoID),
            format: format
        )
    }

    private func quantizationLabel(from fileName: String) -> String? {
        let upper = fileName.uppercased()
        let patterns = [
            #"IQ[1-4]_[A-Z0-9_]+"#,
            #"Q[2-8]_[A-Z0-9_]+"#,
            #"(?:BF|FP|F)16"#,
            #"MXFP4(?:_[A-Z0-9_]+)?"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)),
                  let range = Range(match.range, in: upper) else { continue }
            return String(upper[range]).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        }
        return nil
    }

    private func recommendationRank(for fileName: String) -> Int {
        let upper = fileName.uppercased()
        let priorities = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q3_K_M", "IQ4_XS", "Q6_K", "Q8_0"]
        return priorities.firstIndex(where: { upper.contains($0) }) ?? priorities.count
    }

    func fetchModels() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        do {
            // Fetch popular GGUF repos - just the listing, no per-repo API calls
            let url = URL(string: "https://huggingface.co/api/models?search=gguf+instruct&sort=downloads&direction=-1&limit=20&filter=gguf")!
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config)
            let (data, _) = try await session.data(from: url)

            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                isLoading = false
                return
            }

            let builtInIds = Set(AIModel.sampleModels.map { $0.id })
            var results: [AIModel] = []

            for item in jsonArray {
                guard let modelId = item["modelId"] as? String else { continue }
                let lowerId = modelId.lowercased()
                guard lowerId.contains("gguf") else { continue }

                let cleanId = modelId.replacingOccurrences(of: "/", with: "-").lowercased()
                if builtInIds.contains(cleanId) { continue }

                let displayName = modelId
                    .components(separatedBy: "/").last?
                    .replacingOccurrences(of: "-GGUF", with: "")
                    .replacingOccurrences(of: "-gguf", with: "") ?? modelId

                let downloads = item["downloads"] as? Int ?? 0
                let template = guessTemplate(from: modelId)

                // Estimate size from model name (rough heuristic for display)
                let estimatedSize = estimateSize(from: displayName)

                let model = AIModel(
                    id: cleanId,
                    name: modelId,
                    displayName: displayName,
                    description: "\(downloads.formatted()) downloads on HuggingFace",
                    modelUrl: "", // Will be resolved when user taps download
                    modelSize: estimatedSize,
                    taskIds: [
                        BuiltInTaskID.llmChat.rawValue,
                    ],
                    huggingFaceUrl: "https://huggingface.co/\(modelId)",
                    parameters: AIModel.ModelParameters(
                        temperature: 0.7, topK: 40, topP: 0.95, maxTokens: 1024, randomSeed: 42
                    ),
                    chatTemplate: template
                )

                results.append(model)
                if results.count >= 20 { break }
            }

            remoteModels = results
            print("[HuggingFace] Fetched \(results.count) community models")
        } catch {
            self.error = "Failed to fetch: \(error.localizedDescription)"
            print("[HuggingFace] Error: \(error)")
        }

        isLoading = false
    }

    /// Resolve the actual GGUF download URL for a model (called when user taps download)
    func resolveDownloadURL(for model: AIModel) async -> AIModel? {
        let repo = model.name // stored the full repo id here
        print("[HuggingFace] Resolving download URL for \(repo)")

        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let siblings = json["siblings"] as? [[String: Any]] else { return nil }

            let ggufFiles = siblings.compactMap { file -> (String, Int64)? in
                guard let name = file["rfilename"] as? String,
                      name.hasSuffix(".gguf") else { return nil }
                let size = (file["size"] as? Int64) ?? (file["size"] as? Int).map { Int64($0) } ?? 0
                return (name, size)
            }

            // Prefer Q4_K_M for mobile
            let priorities = ["Q4_K_M", "q4_k_m", "Q4_K_S", "q4_k_s", "Q5_K_M", "Q4_0", "Q8_0"]
            var bestFile: (String, Int64)?

            for priority in priorities {
                if let match = ggufFiles.first(where: { $0.0.contains(priority) }) {
                    bestFile = match
                    break
                }
            }

            if bestFile == nil {
                bestFile = ggufFiles.filter { $0.1 > 0 && $0.1 < 5_000_000_000 }.min(by: { $0.1 < $1.1 })
            }

            guard let (fileName, fileSize) = bestFile else {
                print("[HuggingFace] No suitable GGUF file found in \(repo)")
                return nil
            }

            var resolved = model
            resolved = AIModel(
                id: model.id,
                name: model.name,
                displayName: model.displayName,
                description: model.description,
                modelUrl: "https://huggingface.co/\(repo)/resolve/main/\(fileName)",
                modelSize: fileSize,
                taskIds: model.taskIds,
                huggingFaceUrl: model.huggingFaceUrl,
                parameters: model.parameters,
                chatTemplate: model.chatTemplate
            )

            print("[HuggingFace] Resolved: \(fileName) (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))")
            return resolved

        } catch {
            print("[HuggingFace] Resolve error: \(error)")
            return nil
        }
    }

    private func guessTemplate(from modelId: String) -> ChatTemplate {
        let lower = modelId.lowercased()
        for (key, template) in Self.templateMap {
            if lower.contains(key) { return template }
        }
        return .chatml
    }

    private func estimateSize(from name: String) -> Int64 {
        let lower = name.lowercased()
        if lower.contains("0.5b") { return 500_000_000 }
        if lower.contains("1b") || lower.contains("1.1b") { return 700_000_000 }
        if lower.contains("1.5b") || lower.contains("1.7b") || lower.contains("2b") { return 1_200_000_000 }
        if lower.contains("3b") { return 2_000_000_000 }
        if lower.contains("7b") || lower.contains("8b") { return 4_000_000_000 }
        return 1_500_000_000 // default guess
    }
}
