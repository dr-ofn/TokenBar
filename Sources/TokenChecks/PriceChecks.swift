import Foundation
import LocalCore

// Price checks (Hat B): names, catalogue parsers, lookup order, local models, tiers, the feed's cache.
// Everything here runs without the network: catalogues are small raw texts in each source's own format, and the
// feed is driven by a scripted fetcher or by files. `priceChecks()` is called once from main.swift.

/// A fetcher that answers from a script and counts what was asked.
final class ScriptedFetcher: PriceFetching, @unchecked Sendable {
    enum Answer { case ok(String, etag: String?), notModified, fail, garbage }
    private let lock = NSLock()
    private var answers: [PriceSource: Answer] = [:]
    private var calls: [(source: PriceSource, etag: String?)] = []

    func script(_ source: PriceSource, _ answer: Answer) { lock.withLock { answers[source] = answer } }
    func count(_ source: PriceSource? = nil) -> Int { lock.withLock { calls.filter { source == nil || $0.source == source }.count } }
    func lastEtag(_ source: PriceSource) -> String? { lock.withLock { calls.last { $0.source == source }?.etag ?? nil } }

    func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse {
        let answer: Answer = lock.withLock {
            calls.append((source, etag))
            return answers[source] ?? .fail
        }
        switch answer {
        case .ok(let text, let tag): return .ok(Data(text.utf8), etag: tag)
        case .notModified: return .notModified
        case .garbage: return .ok(Data("<html>not json</html>".utf8), etag: "\"junk\"")
        case .fail: throw PriceFeedError.status(503)
        }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ seconds: TimeInterval) { lock.withLock { t = t.addingTimeInterval(seconds) } }
}

private let openRouterText = """
{"data":[
 {"id":"acme/alpha-1","name":"Acme: Alpha 1","pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003","input_cache_write":"0.00000375",
   "overrides":[{"min_prompt_tokens":200000,"prompt":"0.000006","completion":"0.0000225"},{"utc_start":"00:00","utc_end":"06:00","prompt":"0.000001"}]}},
 {"id":"openrouter/auto","name":"Auto Router","pricing":{"prompt":"-1","completion":"-1"}},
 {"id":"acme/alpha-1:free","name":"Acme: Alpha 1 (free)","pricing":{"prompt":"0","completion":"0"}},
 {"id":"acme/alpha-1:batch","name":"Acme: Alpha 1 (batch)","pricing":{"prompt":"0.0000015","completion":"0.0000075"}},
 {"id":"acme/zero-2","name":"Zero","pricing":{"prompt":"0","completion":"0"}},
 {"id":"vendor/shared-7","name":"Vendor: Shared 7","pricing":{"prompt":"0.000001","completion":"0.000002"}}
]}
"""

private let liteLLMText = """
{"sample_spec":{"input_cost_per_token":1,"output_cost_per_token":1,"mode":"chat"},
 "beta-2":{"mode":"chat","litellm_provider":"beta","input_cost_per_token":3e-6,"output_cost_per_token":1.5e-5,"cache_read_input_token_cost":3e-7,
   "cache_creation_input_token_cost":3.75e-6,"cache_creation_input_token_cost_above_1hr":6e-6,
   "input_cost_per_token_above_200k_tokens":6e-6,"output_cost_per_token_above_200k_tokens":2.25e-5,
   "cache_read_input_token_cost_above_200k_tokens":6e-7,"cache_creation_input_token_cost_above_200k_tokens":7.5e-6},
 "delta-4":{"mode":"chat","input_cost_per_token":1e-6,"output_cost_per_token":2e-6},
 "vertex_ai/delta-4@20250929":{"mode":"chat","input_cost_per_token":1.1e-6,"output_cost_per_token":2.2e-6},
 "us.anthropic.gamma-3-v1:0":{"mode":"chat","input_cost_per_token":5e-6,"output_cost_per_token":2.5e-5},
 "embed-1":{"mode":"embedding","input_cost_per_token":1e-7,"output_cost_per_token":0},
 "free-chat":{"mode":"chat","input_cost_per_token":0,"output_cost_per_token":0},
 "bedrock/shared-7":{"mode":"chat","input_cost_per_token":3e-6,"output_cost_per_token":4e-6},
 "ll-only-8":{"mode":"chat","input_cost_per_token":7e-6,"output_cost_per_token":9e-6,
   "input_cost_per_token_above_128k_tokens":8e-6,"input_cost_per_token_above_272k_tokens":9e-6}}
"""

private let modelsDevText = """
{"prov":{"models":{
   "eps-5":{"name":"Epsilon 5","cost":{"input":2,"output":8,"cache_read":0.5,"cache_write":2.5,
     "tiers":[{"input":4,"output":16,"cache_read":1,"tier":{"type":"context","size":128000}}]}},
   "free-6":{"name":"Free","cost":{"input":0,"output":0}},
   "shared-7":{"name":"Shared Seven","cost":{"input":5,"output":6}},
   "md-only-9":{"name":"MD Nine","cost":{"input":1.5,"output":6,"context_over_200k":{"input":3,"output":9,"cache_read":0.3}}},
   "cons-10":{"cost":{"input":2,"output":4}}}},
 "other":{"models":{"eps-5":{"name":"Epsilon 5","cost":{"input":3,"output":8}},"md-only-9":{"cost":{"input":2.5,"output":7}},
   "cons-10":{"cost":{"input":1,"output":3}}}},
 "third":{"models":{"cons-10":{"cost":{"input":9,"output":9}}}}}
"""

private let rawCatalogs: [PriceSource: Data] = [.openrouter: Data(openRouterText.utf8), .litellm: Data(liteLLMText.utf8),
                                                .modelsdev: Data(modelsDevText.utf8)]

private func rates(_ e: PriceEntry?) -> [Double] {
    guard let r = e?.rates else { return [] }
    return [r.input, r.output, r.cacheRead, r.cacheWrite, r.cacheWrite1h]
}
private func close(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 } }
private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-price-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func price(_ model: String, _ provider: String = "") -> PriceEntry? { ModelPrice(model: model, provider: provider).entry }
private func cost(_ model: String, _ provider: String = "", input: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0) -> Double {
    ModelPrice(model: model, provider: provider).cost(TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output))
}

/// Raw name -> key1, key2, quant key ("" when the name carries no local quantisation suffix).
/// Names as logs spell them, plus the spellings the brief lists (Bedrock, Vertex, OpenRouter, Ollama, GGUF ...).
private let normalizationTable: [(String, String, String, String)] = [
        ("MiniMaxAI/MiniMax-M2.7", "minimax-m2-7", "minimax-m2-7", ""),
        ("baidu/ernie-5.5-flash-preview:free", "ernie-5-5-flash-preview", "ernie-5-5-flash-preview", ""),
        ("beam-free", "beam-free", "beam", ""),
        ("big-pickle", "big-pickle", "big-pickle", ""),
        ("cat-jam-free", "cat-jam-free", "cat-jam", ""),
        ("claude-fable-5-1", "claude-fable-5-1", "claude-fable-5-1", ""),
        ("claude-fable-5-2", "claude-fable-5-2", "claude-fable-5-2", ""),
        ("claude-haiku-5-5", "claude-haiku-5-5", "claude-haiku-5-5", ""),
        ("claude-mythos-5-2", "claude-mythos-5-2", "claude-mythos-5-2", ""),
        ("claude-opus-4-6-thinking", "claude-opus-4-6-thinking", "claude-opus-4-6", ""),
        ("claude-opus-5-5", "claude-opus-5-5", "claude-opus-5-5", ""),
        ("claude-sonnet-5-5", "claude-sonnet-5-5", "claude-sonnet-5-5", ""),
        ("claude-sonnet-5-5-high", "claude-sonnet-5-5-high", "claude-sonnet-5-5-high", ""),
        ("cohere/north-mini-code:free", "north-mini-code", "north-mini-code", ""),
        ("deepseek-ai/DeepSeek-V4-Flash-0731", "deepseek-v4-flash-0731", "deepseek-v4-flash-0731", ""),
        ("deepseek-v4.1-flash", "deepseek-v4-1-flash", "deepseek-v4-1-flash", ""),
        ("deepseek-v4.1-flash-free", "deepseek-v4-1-flash-free", "deepseek-v4-1-flash", ""),
        ("deepseek/deepseek-v4.1-flash", "deepseek-v4-1-flash", "deepseek-v4-1-flash", ""),
        ("flint-40b-free", "flint-40b-free", "flint-40b", ""),
        ("gemini-3.1-pro-low", "gemini-3-1-pro-low", "gemini-3-1-pro-low", ""),
        ("gemini-3.6-flash", "gemini-3-6-flash", "gemini-3-6-flash", ""),
        ("gemini-3.7-flash", "gemini-3-7-flash", "gemini-3-7-flash", ""),
        ("gemini-3.8-flash", "gemini-3-8-flash", "gemini-3-8-flash", ""),
        ("gemini-3.8-flash-n", "gemini-3-8-flash-n", "gemini-3-8-flash-n", ""),
        ("gemini-4-argon-trial", "gemini-4-argon-trial", "gemini-4-argon-trial", ""),
        ("gemini-4-hydrogen", "gemini-4-hydrogen", "gemini-4-hydrogen", ""),
        ("gemini-4-neon", "gemini-4-neon", "gemini-4-neon", ""),
        ("gemma-4-12b", "gemma-4-12b", "gemma-4-12b", ""),
        ("gemma-4-26b-a4b", "gemma-4-26b-a4b", "gemma-4-26b-a4b", ""),
        ("gemma-4-e2b", "gemma-4-e2b", "gemma-4-e2b", ""),
        ("gemma-4-e4b", "gemma-4-e4b", "gemma-4-e4b", ""),
        ("gemma4-12b-v2", "gemma4-12b-v2", "gemma4-12b-v2", ""),
        ("gemma4-26b", "gemma4-26b", "gemma4-26b", ""),
        ("glm-4.5-flash", "glm-4-5-flash", "glm-4-5-flash", ""),
        ("glm-4.6v-flash", "glm-4-6v-flash", "glm-4-6v-flash", ""),
        ("glm-4.7-flash", "glm-4-7-flash", "glm-4-7-flash", ""),
        ("glm-4.7-flashx", "glm-4-7-flashx", "glm-4-7-flashx", ""),
        ("glm-5.2", "glm-5-2", "glm-5-2", ""),
        ("glm-5.3", "glm-5-3", "glm-5-3", ""),
        ("glm-5.3-flash", "glm-5-3-flash", "glm-5-3-flash", ""),
        ("glm-5.3-flash-free", "glm-5-3-flash-free", "glm-5-3-flash", ""),
        ("glm-5v-turbo", "glm-5v-turbo", "glm-5v-turbo", ""),
        ("gpt-5.6-luna", "gpt-5-6-luna", "gpt-5-6-luna", ""),
        ("gpt-5.6-terra", "gpt-5-6-terra", "gpt-5-6-terra", ""),
        ("gpt-6-astra", "gpt-6-astra", "gpt-6-astra", ""),
        ("gpt-6-luna", "gpt-6-luna", "gpt-6-luna", ""),
        ("gpt-6.1-sol", "gpt-6-1-sol", "gpt-6-1-sol", ""),
        ("gpt-6.1-terra", "gpt-6-1-terra", "gpt-6-1-terra", ""),
        ("gpt-6.2-astra", "gpt-6-2-astra", "gpt-6-2-astra", ""),
        ("gpt-oss-120b-medium", "gpt-oss-120b-medium", "gpt-oss-120b-medium", ""),
        ("haiku", "haiku", "haiku", ""),
        ("heretic-gemma-4-26b-a4b", "heretic-gemma-4-26b-a4b", "heretic-gemma-4-26b-a4b", ""),
        ("hy4-flash-free", "hy4-flash-free", "hy4-flash", ""),
        ("hy4-preview", "hy4-preview", "hy4-preview", ""),
        ("iceman-contributor-free", "iceman-contributor-free", "iceman-contributor", ""),
        ("iceman-free", "iceman-free", "iceman", ""),
        ("inkling-2-small-free", "inkling-2-small-free", "inkling-2-small", ""),
        ("kimi-k3.1-pro", "kimi-k3-1-pro", "kimi-k3-1-pro", ""),
        ("lfm2.5-24b-a2b", "lfm2-5-24b-a2b", "lfm2-5-24b-a2b", ""),
        ("lfm25-vl", "lfm25-vl", "lfm25-vl", ""),
        ("ling-3.0-tiny", "ling-3-0-tiny", "ling-3-0-tiny", ""),
        ("ling-3.1-flash-free", "ling-3-1-flash-free", "ling-3-1-flash", ""),
        ("longcat-2.5-free", "longcat-2-5-free", "longcat-2-5", ""),
        ("longcat-2.5-preview-free", "longcat-2-5-preview-free", "longcat-2-5-preview", ""),
        ("meituan/longcat-2.5:free", "longcat-2-5", "longcat-2-5", ""),
        ("mimo-v2.6-distill-qwen-9b", "mimo-v2-6-distill-qwen-9b", "mimo-v2-6-distill-qwen-9b", ""),
        ("mimo-v2.6-flash", "mimo-v2-6-flash", "mimo-v2-6-flash", ""),
        ("mimo-v2.6-flash-free", "mimo-v2-6-flash-free", "mimo-v2-6-flash", ""),
        ("minicpm-v-4.7-1b", "minicpm-v-4-7-1b", "minicpm-v-4-7-1b", ""),
        ("minicpm-v-4.7-35b-a3b", "minicpm-v-4-7-35b-a3b", "minicpm-v-4-7-35b-a3b", ""),
        ("minimax-m3.1-flash-free", "minimax-m3-1-flash-free", "minimax-m3-1-flash", ""),
        ("muse-spark-1.3-contributor", "muse-spark-1-3-contributor", "muse-spark-1-3-contributor", ""),
        ("muse-spark-1.3-contributor-free", "muse-spark-1-3-contributor-free", "muse-spark-1-3-contributor", ""),
        ("nemotron-3-ultra-free", "nemotron-3-ultra-free", "nemotron-3-ultra", ""),
        ("nemotron-3.5-lightning-free", "nemotron-3-5-lightning-free", "nemotron-3-5-lightning", ""),
        ("nemotron-3.5-super-vl-free", "nemotron-3-5-super-vl-free", "nemotron-3-5-super-vl", ""),
        ("nemotron-bolt-e4b", "nemotron-bolt-e4b", "nemotron-bolt-e4b", ""),
        ("nvidia/nemotron-3-nano-omni-30b-a3b-reasoning", "nemotron-3-nano-omni-30b-a3b-reasoning", "nemotron-3-nano-omni-30b-a3b-reasoning", ""),
        ("nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "nemotron-3-nano-omni-30b-a3b-reasoning", "nemotron-3-nano-omni-30b-a3b-reasoning", ""),
        ("nvidia/nemotron-3-ultra-550b-a55b:free", "nemotron-3-ultra-550b-a55b", "nemotron-3-ultra-550b-a55b", ""),
        ("nvidia/nemotron-3.5-bolt-e4b:free", "nemotron-3-5-bolt-e4b", "nemotron-3-5-bolt-e4b", ""),
        ("nvidia/nemotron-3.5-lightning:free", "nemotron-3-5-lightning", "nemotron-3-5-lightning", ""),
        ("nvidia/nemotron-3.5-super-vl-120b-a12b", "nemotron-3-5-super-vl-120b-a12b", "nemotron-3-5-super-vl-120b-a12b", ""),
        ("nvidia/nemotron-3.5-super-vl-120b-a12b:free", "nemotron-3-5-super-vl-120b-a12b", "nemotron-3-5-super-vl-120b-a12b", ""),
        ("nvidia/nemotron-3.5-super-vl:free", "nemotron-3-5-super-vl", "nemotron-3-5-super-vl", ""),
        ("openrouter/free", "free", "free", ""),
        ("ornith-1.5-35b-a3b", "ornith-1-5-35b-a3b", "ornith-1-5-35b-a3b", ""),
        ("ornith-1.5-9b", "ornith-1-5-9b", "ornith-1-5-9b", ""),
        ("pulse-alpha-free", "pulse-alpha-free", "pulse-alpha", ""),
        ("qwen3.8-27b", "qwen3-8-27b", "qwen3-8-27b", ""),
        ("qwen3.8-flash-next", "qwen3-8-flash-next", "qwen3-8-flash-next", ""),
        ("qwen3.8-flash-next-256k", "qwen3-8-flash-next-256k", "qwen3-8-flash-next-256k", ""),
        ("qwen3.8-flash-next-q2_0", "qwen3-8-flash-next-q2-0", "qwen3-8-flash-next-q2-0", "qwen3-8-flash-next"),
        ("recursive/flint-v1.0:free", "flint-v1-0", "flint-v1-0", ""),
        ("reflection/beam-1.0", "beam-1-0", "beam-1-0", ""),
        ("space-bunny-free", "space-bunny-free", "space-bunny", ""),
        ("stealth/crouton-alpha", "crouton-alpha", "crouton-alpha", ""),
        ("step-5-preview", "step-5-preview", "step-5-preview", ""),
        ("step-5-preview-free", "step-5-preview-free", "step-5-preview", ""),
        ("swe-1-6-slow", "swe-1-6-slow", "swe-1-6-slow", ""),
        ("swe-2-flash-medium", "swe-2-flash-medium", "swe-2-flash-medium", ""),
        ("tencent/hy4-preview-free", "hy4-preview-free", "hy4-preview", ""),
        ("ternary-bonsai-2-27b", "ternary-bonsai-2-27b", "ternary-bonsai-2-27b", ""),
        ("thinkingmachines/inkling-small:free", "inkling-small", "inkling-small", ""),
        ("thinkingmachines/inkling:free", "inkling", "inkling", ""),
        ("xingchen-agi/xing4.0-29b-a4b:free", "xing4-0-29b-a4b", "xing4-0-29b-a4b", ""),
        ("zai-org/GLM-5.3-Flash", "glm-5-3-flash", "glm-5-3-flash", ""),
        ("anthropic/claude-sonnet-4.5", "claude-sonnet-4-5", "claude-sonnet-4-5", ""),
        ("openai/gpt-6-luna", "gpt-6-luna", "gpt-6-luna", ""),
        ("bedrock/anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5", "claude-sonnet-4-5", ""),
        ("vertex_ai/claude-sonnet-4-5@20250929", "claude-sonnet-4-5", "claude-sonnet-4-5", ""),
        ("openrouter/anthropic/claude-opus-4.6", "claude-opus-4-6", "claude-opus-4-6", ""),
        ("us.anthropic.claude-opus-4-6-v1:0", "claude-opus-4-6", "claude-opus-4-6", ""),
        ("eu.anthropic.claude-sonnet-4-6-v1:0", "claude-sonnet-4-6", "claude-sonnet-4-6", ""),
        ("global.anthropic.claude-haiku-5-5-v1:0", "claude-haiku-5-5", "claude-haiku-5-5", ""),
        ("claude-opus-4-6-latest", "claude-opus-4-6-latest", "claude-opus-4-6", ""),
        ("claude-3-5-sonnet-20241022", "claude-3-5-sonnet", "claude-3-5-sonnet", ""),
        ("claude-opus-5-5[1m]", "claude-opus-5-5", "claude-opus-5-5", ""),
        ("claude-opus-5-5[200k]", "claude-opus-5-5", "claude-opus-5-5", ""),
        ("claude-sonnet-5-5-thinking", "claude-sonnet-5-5-thinking", "claude-sonnet-5-5", ""),
        ("claude-opus-4.6", "claude-opus-4-6", "claude-opus-4-6", ""),
        ("gpt-6.1-sol:batch", "gpt-6-1-sol", "gpt-6-1-sol", ""),
        ("google/gemini-4-neon:thinking", "gemini-4-neon", "gemini-4-neon", ""),
        ("deepseek-v4.1-flash:free", "deepseek-v4-1-flash", "deepseek-v4-1-flash", ""),
        ("qwen3.8-27b-4bit", "qwen3-8-27b-4bit", "qwen3-8-27b-4bit", "qwen3-8-27b"),
        ("qwen3.8-27b-8bit", "qwen3-8-27b-8bit", "qwen3-8-27b-8bit", "qwen3-8-27b"),
        ("Qwen3.6-35B-A3B-Q4_K_M", "qwen3-6-35b-a3b-q4-k-m", "qwen3-6-35b-a3b-q4-k-m", "qwen3-6-35b-a3b"),
        ("qwen3-coder-30b-a3b-instruct-q2_0", "qwen3-coder-30b-a3b-instruct-q2-0", "qwen3-coder-30b-a3b-instruct-q2-0", "qwen3-coder-30b-a3b-instruct"),
        ("gemma-4-26b-a4b-it-mlx", "gemma-4-26b-a4b-it-mlx", "gemma-4-26b-a4b-it-mlx", "gemma-4-26b-a4b-it"),
        ("llama-3.3-70b-instruct-gguf", "llama-3-3-70b-instruct-gguf", "llama-3-3-70b-instruct-gguf", "llama-3-3-70b-instruct"),
        ("mistral-small-3.2-24b-instruct-2506-dwq", "mistral-small-3-2-24b-instruct-2506-dwq", "mistral-small-3-2-24b-instruct-2506-dwq", "mistral-small-3-2-24b-instruct-2506"),
        ("qwen3-8b-awq", "qwen3-8b-awq", "qwen3-8b-awq", "qwen3-8b"),
        ("llama3.1:8b", "llama3-1-8b", "llama3-1-8b", ""),
        ("qwen3:30b-a3b", "qwen3-30b-a3b", "qwen3-30b-a3b", ""),
        ("gpt-4o-2024-08-06", "gpt-4o", "gpt-4o", ""),
        ("gpt-5-2025-08-07", "gpt-5", "gpt-5", ""),
        ("gemini-2.5-pro", "gemini-2-5-pro", "gemini-2-5-pro", ""),
        ("azure/gpt-6-luna-2026-09-22", "gpt-6-luna", "gpt-6-luna", ""),
        ("claude-opus-4-6@20260115", "claude-opus-4-6", "claude-opus-4-6", ""),
        ("claude-sonnet-4-5@default", "claude-sonnet-4-5", "claude-sonnet-4-5", ""),
        ("apac.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5", "claude-sonnet-4-5", ""),
        ("meta.llama3-2-11b-instruct-v1:0", "llama3-2-11b-instruct", "llama3-2-11b-instruct", ""),
        ("us.meta.llama3-2-11b-instruct-v1:0", "llama3-2-11b-instruct", "llama3-2-11b-instruct", ""),
        ("accounts/fireworks/models/llama-v3p1-70b-instruct", "llama-v3p1-70b-instruct", "llama-v3p1-70b-instruct", ""),
        ("models/gemini-2.5-flash", "gemini-2-5-flash", "gemini-2-5-flash", ""),
        ("claude-opus-5-5 (high)", "claude-opus-5-5", "claude-opus-5-5", ""),
        ("  Claude-Opus-5-5  ", "claude-opus-5-5", "claude-opus-5-5", ""),
        ("anthropic/claude-3.7-sonnet:thinking", "claude-3-7-sonnet", "claude-3-7-sonnet", ""),
        ("openai/gpt-4.1-2025-04-14", "gpt-4-1", "gpt-4-1", ""),
]

func priceChecks() {
    // MARK: names

    check("name table has 100+ real names", normalizationTable.count >= 100)
    var wrong: [String] = []
    for (raw, key1, key2, quant) in normalizationTable {
        let k = ModelNames.keys(raw)
        if k.key1 != key1 || k.key2 != key2 || (k.quant ?? "") != quant { wrong.append("\(raw) -> \(k.key1) | \(k.key2) | \(k.quant ?? "")") }
    }
    check("every name in the table folds to its expected key" + (wrong.isEmpty ? "" : " (\(wrong.prefix(3)))"), wrong.isEmpty)
    check("brief's folding rules", ModelNames.keys("claude-opus-4.6").key2 == ModelNames.keys("claude-opus-4-6").key2
          && ModelNames.keys("vertex_ai/claude-sonnet-4-5@20250929").key2 == "claude-sonnet-4-5"
          && ModelNames.keys("bedrock/us.anthropic.claude-opus-4-6-v1:0").key2 == "claude-opus-4-6"
          && ModelNames.keys("claude-opus-4-6-latest").key2 == "claude-opus-4-6"
          && ModelNames.keys("Claude-Opus-5-5[1m]").key2 == "claude-opus-5-5"
          && ModelNames.keys("gpt-6.1-sol:batch").key2 == "gpt-6-1-sol"
          && ModelNames.keys("qwen3.8-27b-4bit").quant == "qwen3-8-27b"
          && ModelNames.keys("llama-3.3-70b-q4_k_m").quantised && !ModelNames.keys("llama-3.3-70b").quantised)
    check("normalize drops provider path and free mark", PriceBook.normalize("Anthropic/CLAUDE-OPUS-5-5:FREE") == "claude-opus-5-5")

    // MARK: parsers (units, rejected rows, tiers)

    let ors = PriceCatalogs.fromRaw([.openrouter: rawCatalogs[.openrouter]!])
    let lls = PriceCatalogs.fromRaw([.litellm: rawCatalogs[.litellm]!])
    let mds = PriceCatalogs.fromRaw([.modelsdev: rawCatalogs[.modelsdev]!])
    PriceBook.install(catalogs: ors)
    let alpha = price("acme/alpha-1")
    check("OpenRouter: string USD per token becomes USD per million", close(rates(alpha), [3, 15, 0.3, 3.75, 3.75]) && alpha?.kind == .openrouter)
    check("OpenRouter: only a prompt-length override is a tier", alpha?.tiers.count == 1 && alpha?.tiers.first?.minPrompt == 200_000
          && close([alpha?.tiers.first?.rates.input ?? 0, alpha?.tiers.first?.rates.output ?? 0], [6, 22.5]))
    // 9.0.1: a tier that does not state a cache price keeps the base row's (0.3), as a LiteLLM tier does; it used to
    // fall to the tier's input price (6), which priced a cache read at twice the base's input.
    check("OpenRouter: a missing tier cache price is the base row's, not the tier's input price", alpha?.tiers.first?.rates.cacheRead == 0.3)
    check("OpenRouter: -1 routers and zero prices are ignored", price("openrouter/auto") == nil && price("acme/zero-2") == nil)
    check("OpenRouter: a :batch row is its own price when asked by id, and never the bare name's", close(rates(price("acme/alpha-1:batch")), [1.5, 7.5, 1.5, 1.5, 1.5])
          && close(rates(price("alpha-1")), [3, 15, 0.3, 3.75, 3.75]) && close(rates(price("acme/alpha-1:free")), [3, 15, 0.3, 3.75, 3.75]))
    check("a catalogue row remembers its catalogue and id", alpha?.catalog == "OpenRouter" && alpha?.catalogID == "acme/alpha-1"
          && alpha?.source == "OpenRouter: acme/alpha-1" && alpha?.name == "Alpha 1")

    PriceBook.install(catalogs: lls)
    let beta = price("beta-2")
    check("LiteLLM: number USD per token, cache and 1-hour prices", close(rates(beta), [3, 15, 0.3, 3.75, 6]) && beta?.kind == .litellm)
    check("LiteLLM: an _above_200k_ field is a tier above 200,000 tokens", beta?.tiers.count == 1 && beta?.tiers.first?.minPrompt == 200_001
          && close([beta?.tiers.first?.rates.input ?? 0, beta?.tiers.first?.rates.cacheRead ?? 0, beta?.tiers.first?.rates.cacheWrite ?? 0], [6, 0.6, 7.5]))
    let multi = price("ll-only-8")
    check("LiteLLM: several thresholds make ordered tiers that carry earlier prices on",
          multi?.tiers.map(\.minPrompt) == [128_001, 272_001] && multi?.tiers.last?.rates.output == 9 && multi?.tiers.last?.rates.input == 9
          && multi?.tiers.first?.rates.input == 8)
    check("LiteLLM: sample_spec, embeddings and zero prices are not models", price("sample_spec") == nil && price("embed-1") == nil && price("free-chat") == nil)
    check("LiteLLM: the exact id keeps its own price", close(rates(price("vertex_ai/delta-4@20250929")), [1.1, 2.2, 1.1, 1.1, 1.1])
          && close(rates(price("delta-4")), [1, 2, 1, 1, 1]))
    check("LiteLLM: a Bedrock id reads as its model", price("anthropic.gamma-3") != nil && price("us.anthropic.gamma-3-v1:0") != nil
          && price("gamma-3")?.rates.input == 5)

    PriceBook.install(catalogs: mds)
    let eps = price("eps-5")
    check("models.dev: USD per million as they are, a tier above the context size", eps?.kind == .modelsdev && close(rates(eps), [2, 8, 0.5, 2.5, 2.5])
          && eps?.tiers.first?.minPrompt == 128_001 && eps?.tiers.first?.rates.input == 4)
    check("models.dev: context_over_200k is a tier above 200,000", price("md-only-9")?.tiers.first?.minPrompt == 200_001
          && price("md-only-9")?.tiers.first?.rates.cacheRead == 0.3)
    check("models.dev: zero prices are not models; the provider is not part of the name", price("free-6") == nil && eps?.catalogID == "prov/eps-5"
          && eps?.name == "Epsilon 5")
    check("models.dev: of many providers the middle price speaks for the model", price("cons-10")?.catalogID == "prov/cons-10" && price("cons-10")?.rates.input == 2)

    // MARK: lookup order

    PriceBook.install(catalogs: PriceCatalogs.fromRaw(rawCatalogs))
    check("order: OpenRouter before LiteLLM before models.dev", price("shared-7")?.kind == .openrouter && price("shared-7")?.rates.input == 1)
    PriceBook.install(catalogs: PriceCatalogs.fromRaw([.litellm: rawCatalogs[.litellm]!, .modelsdev: rawCatalogs[.modelsdev]!]))
    check("order: LiteLLM before models.dev when OpenRouter is absent", price("shared-7")?.kind == .litellm && price("shared-7")?.rates.input == 3)
    PriceBook.install(catalogs: PriceCatalogs.fromRaw([.modelsdev: rawCatalogs[.modelsdev]!]))
    check("order: models.dev when it is all there is", price("shared-7")?.kind == .modelsdev && price("shared-7")?.rates.input == 5)
    PriceBook.install(catalogs: PriceCatalogs.fromRaw(rawCatalogs))
    check("an exact catalogue id wins over the folded name", price("acme/alpha-1")?.kind == .openrouter && price("vendor/shared-7")?.catalogID == "vendor/shared-7")
    check("a free route is priced at the list price", close(rates(price("acme/alpha-1:free")), [3, 15, 0.3, 3.75, 3.75])
          && close(rates(price("alpha-1-free")), [3, 15, 0.3, 3.75, 3.75]) && price("alpha-1-free")?.kind == .openrouter)
    check("a model nothing lists has no price", price("nobody-ever-listed-this", "openai") == nil && !ModelPrice(model: "nobody-ever-listed-this").isPriced)

    // MARK: family proxy

    let family = price("alpha-1-high")
    check("family proxy: an effort word is dropped and the row is marked approximate", family?.kind == .approximate && close(rates(family), rates(alpha))
          && family?.source.hasPrefix("yaklaşık: alpha-1-high → alpha-1") == true)
    check("family proxy: an account number or context size is dropped", price("alpha-1-1234")?.kind == .approximate && price("alpha-1-256k")?.kind == .approximate)
    check("family proxy: a real name never goes through it", price("alpha-1")?.kind == .openrouter && price("delta-4")?.kind == .litellm)
    check("family proxy: at most two steps", price("alpha-1-high-1234")?.kind == .approximate && price("alpha-1-high-1234-low") == nil)

    // MARK: tiers

    PriceBook.install(catalogs: PriceCatalogs.fromRaw(rawCatalogs))
    check("tier: OpenRouter starts at its own number (>= 200,000)", close([cost("acme/alpha-1", input: 199_999)], [199_999 * 3 / 1e6])
          && close([cost("acme/alpha-1", input: 200_000)], [200_000 * 6 / 1e6]))
    check("tier: LiteLLM starts above its threshold (> 200,000)", close([cost("beta-2", input: 200_000)], [200_000 * 3 / 1e6])
          && close([cost("beta-2", input: 200_001)], [200_001 * 6 / 1e6]))
    check("tier: the prompt counts fresh, cached and written tokens", close([cost("beta-2", input: 100_000, cacheRead: 100_000, cacheWrite: 1)],
                                                                             [(100_000 * 6 + 100_000 * 0.6 + 7.5) / 1e6]))
    check("tier: the last tier the prompt reaches", close([cost("ll-only-8", input: 130_000)], [130_000 * 8 / 1e6])
          && close([cost("ll-only-8", input: 300_000)], [300_000 * 9 / 1e6]))
    check("tier: a summed row has no tier", close([ModelPrice(model: "beta-2").baseParts(TokenCounts(input: 500_000)).total], [500_000 * 3 / 1e6]))
    check("one-hour cache writes keep their own price", close([ModelPrice(model: "beta-2").baseParts(TokenCounts(cacheWrite: 1_000_000, cacheWrite1h: 400_000)).total],
                                                              [(600_000 * 3.75 + 400_000 * 6) / 1e6]))

    // MARK: local models

    check("local: a provider on this Mac with a cloud counterpart is priced as it", price("alpha-1", "ollama")?.kind == .localCloud
          && close(rates(price("alpha-1", "ollama")), rates(alpha)) && price("alpha-1", "OMLX")?.kind == .localCloud
          && price("alpha-1", "lm_studio")?.kind == .localCloud && price("alpha-1", "llama.cpp")?.kind == .localCloud
          && price("alpha-1", "ollama")?.source == "yerel → bulut karşılığı: OpenRouter: acme/alpha-1")
    check("local: a quantisation suffix makes the name local whatever the provider", price("alpha-1-4bit", "")?.kind == .localCloud
          && price("acme/alpha-1-q4_k_m", "xx-cloud")?.kind == .localCloud && price("alpha-1-8bit-mlx")?.kind == .localCloud
          && close(rates(price("alpha-1-4bit")), rates(alpha)))
    let free = price("home-brew-7b", "ollama")
    check("local: no cloud counterpart costs nothing, and says so", free?.kind == .localFree && free?.source == "yerel, bulut karşılığı yok"
          && ModelPrice(model: "home-brew-7b", provider: "ollama").isPriced && cost("home-brew-7b", "ollama", input: 1_000_000, output: 1_000_000) == 0
          && price("home-brew-7b-q4_k_m")?.kind == .localFree && price("home-brew-7b-gguf", "openai")?.kind == .localFree)
    check("local: a cloud model that nothing lists stays unpriced", price("home-brew-7b", "openai") == nil && price("home-brew-7b", "zai") == nil)
    check("local: a tier still applies to the cloud counterpart", close([cost("alpha-1", "ollama", input: 250_000)], [250_000 * 6 / 1e6]))
    check("local: the family proxy is not used (a guess would charge a local model)", price("alpha-1-high", "ollama")?.kind == .localFree)

    // MARK: the user's alias file

    do {
        let dir = tempDirectory()
        let path = dir.appendingPathComponent("model-aliases.json").path
        try? """
        {"aliases": {"my-alpha": "acme/alpha-1", "Sidecar-X": {"as": "delta-4"}, "house": {"input": 1, "output": 4, "name": "House Model"},
                     "scratch": {"free": true}, "broken": 5, "empty": ""},
         "localProviders": ["Studio", "my_mac"]}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let aliases = UserAliases.load(path: path)
        check("aliases: file is read, broken entries dropped", aliases.targets.count == 4 && aliases.localProviders == ["studio", "my-mac"])
        PriceBook.install(catalogs: PriceCatalogs.fromRaw(rawCatalogs), aliases: aliases)
        check("aliases: a name prices like another model", price("my-alpha")?.kind == .alias && close(rates(price("my-alpha")), rates(alpha))
              && price("my-alpha")?.source.hasPrefix("kullanıcı takma adı: my-alpha → acme/alpha-1") == true)
        check("aliases: an alias beats the catalogues; names fold like any name", close(rates(price("sidecar-x")), rates(price("delta-4"))) && price("Sidecar-X")?.kind == .alias)
        check("aliases: a price written out", close(rates(price("house")), [1, 4, 1, 1, 1]) && price("house")?.name == "House Model")
        check("aliases: free costs nothing", price("scratch")?.kind == .localFree && cost("scratch", input: 1_000_000) == 0)
        check("aliases: the user's local providers", price("alpha-1", "studio")?.kind == .localCloud && price("zzz-unknown", "my_mac")?.kind == .localFree
              && price("zzz-unknown", "elsewhere") == nil)
        check("aliases: a missing or foreign file is no aliases", UserAliases.load(path: dir.path + "/none.json").targets.isEmpty
              && UserAliases(json: Data("[1,2]".utf8)).targets.isEmpty && UserAliases(json: Data("{\"x\": \"acme/alpha-1\"}".utf8)).targets.count == 1)
        check("aliases: an alias for the short name covers numbered variants as an approximation",
              price("my-alpha-4242")?.kind == .approximate && price("my-alpha-high")?.kind == .approximate
              && close(rates(price("my-alpha-4242")), rates(alpha)) && price("my-alpha-4242")?.source.contains("kullanıcı takma adı: my-alpha") == true)
        check("an account number is only the family proxy's business",
              price("deepseek-v4.1-flash-4242")?.kind == .approximate && price("deepseek-v4.1-flash")?.kind == .openrouter)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: revision

    var changes = 0
    let observer = NotificationCenter.default.addObserver(forName: PriceBook.didChange, object: nil, queue: nil) { _ in changes += 1 }
    let before = PriceBook.revision
    PriceBook.install(catalogs: .embedded)
    check("revision counts up when the prices change, and says so", PriceBook.revision == before + 1 && changes == 1)
    NotificationCenter.default.removeObserver(observer)

    // MARK: the embedded snapshot

    let snapshotURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LocalCore/Resources/prices-snapshot.json")
    let fileText = (try? String(contentsOf: snapshotURL, encoding: .utf8))?.trimmingCharacters(in: .newlines)
    let embedded = PriceCatalogs.embeddedSnapshotText
    check("snapshot: the compiled text is the file in Resources", fileText == embedded.trimmingCharacters(in: .newlines))
    check("snapshot: under 1.5 MB", embedded.utf8.count < 1_500_000)
    let root = (try? JSONSerialization.jsonObject(with: Data(embedded.utf8))) as? [String: Any]
    let sources = root?["sources"] as? [String: [String: String]]
    let litellmInfo = sources?["litellm"], modelsdevInfo = sources?["modelsdev"]
    let datedAndLicensed: Bool = (root?["generated"] as? String)?.count == 10
        && litellmInfo?["url"]?.contains("BerriAI/litellm") == true && modelsdevInfo?["url"] == "https://models.dev/api.json"
        && litellmInfo?["license"]?.hasPrefix("MIT") == true && modelsdevInfo?["license"]?.hasPrefix("MIT") == true
        && litellmInfo?["licenseUrl"] != nil && modelsdevInfo?["licenseUrl"] != nil
    check("snapshot: source URLs, dates and MIT licence notes are inside", datedAndLicensed)
    check("snapshot: no OpenRouter data is embedded", root?["openrouter"] == nil && !embedded.contains("openrouter.ai/api") && PriceCatalogs.embedded.origins[.openrouter] == nil)
    PriceBook.install(catalogs: .embedded)
    let common = ["gpt-4o", "gpt-4.1", "gemini-2.5-pro", "claude-sonnet-4-5", "deepseek-chat"].filter { price($0, "openai")?.kind == .litellm || price($0, "openai")?.kind == .modelsdev }
    check("snapshot: it prices well-known models with no table row (\(common.count) of 5)", common.count >= 3)
    // The table wins over a LiteLLM or models.dev row. (Over a live OpenRouter row it gives way, when it is a copy of an
    // OpenRouter price: see the 9.0.1 checks.)
    PriceBook.install(catalogs: PriceCatalogs.fromRaw([.litellm: Data("{\"claude-opus-5-5\":{\"mode\":\"chat\",\"input_cost_per_token\":1e-6,\"output_cost_per_token\":2e-6}}".utf8)]))
    check("override layer: the hand-corrected table wins over a catalogue", price("claude-opus-5-5")?.catalogID == nil && price("claude-opus-5-5")?.rates.input == 4
          && price("big-pickle")?.kind == .near)
    check("override layer: a free mark still reaches the table's row", price("beam-free")?.kind == .near)
    check("override layer: a claude-opus-5-5[1m] name is the same model", price("claude-opus-5-5[1m]")?.rates.input == 4)
    do {
        let mine = UserAliases(json: Data(#"{"aliases": {"my-opus": "claude-opus-5-5", "home-brew": {"input": 0.15, "output": 1.875, "name": "Home Brew"}}, "localProviders": ["studio"]}"#.utf8))
        PriceBook.install(catalogs: .embedded, aliases: mine)
        check("alias layer: an alias reaches a table row, a written price and a local provider",
              price("my-opus")?.kind == .alias && price("my-opus")?.rates.input == 4 && price("home-brew", "studio")?.name == "Home Brew"
              && price("zzz-unknown", "studio")?.kind == .localFree)
    }
    PriceBook.install(catalogs: .embedded)
    check("no user's own names in the general build", price("haiku") == nil && price("claude-haiku-5-5")?.rates.input == 0.1)
    check("free-only routes as the logs spell them take the nearest paid model's price",
          price("nvidia/nemotron-3.5-bolt-e4b:free", "anyrouter")?.kind == .near && price("nvidia/nemotron-3.5-super-vl-120b-a12b:free", "anyrouter")?.rates.input == 0.15
          && price("nvidia/nemotron-3.5-super-vl-120b-a12b", "openai")?.rates.output == 0.47 && price("flint-40b-free", "opencode")?.kind == .near
          && price("baidu/ernie-5.5-flash-preview:free", "openrouter")?.kind == .near && price("gemini-4-argon-trial", "google-antigravity")?.rates.output == 10)
    check("a stealth model with no paid counterpart stays unpriced (no invented price)", price("iceman-free", "opencode") == nil && price("iceman-contributor-free", "anyrouter") == nil)

    // MARK: the feed: cache, ETag, TTL, offline, broken answers

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func makeFeed(_ dir: URL, _ fetcher: PriceFetching, _ clock: Clock, offline: Bool = false) -> PriceFeed {
        var config = PriceFeed.Config(cacheDirectory: dir, offline: offline, fetcher: fetcher)
        config.now = { clock.now }
        return PriceFeed(config)
    }
    func cacheFiles(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("prices-") && $0 != "prices-state.json" }.sorted() }
    func installLocal(_ feed: PriceFeed) { PriceBook.install(catalogs: feed.loadLocal()) }

    do { // no network, no cache: the embedded snapshot
        let dir = tempDirectory(), clock = Clock(t0), fetcher = ScriptedFetcher()
        let feed = makeFeed(dir, fetcher, clock)
        let local = feed.loadLocal()
        let report = feed.refreshBlocking()
        check("feed: nothing on disk and no network falls back to the snapshot", local.origins[.litellm] != nil && local.origins[.openrouter] == nil
              && report.failed.count == 3 && report.changed == false && cacheFiles(dir).isEmpty && feed.loadLocal().origins[.openrouter] == nil)
        try? FileManager.default.removeItem(at: dir)
    }
    do { // 200, then fresh within the TTL, then 304 after it
        let dir = tempDirectory(), clock = Clock(t0), fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(openRouterText, etag: "\"or-1\""))
        fetcher.script(.litellm, .ok(liteLLMText, etag: "\"ll-1\""))
        fetcher.script(.modelsdev, .ok(modelsDevText, etag: nil))
        let feed = makeFeed(dir, fetcher, clock)
        let first = feed.refreshBlocking()
        check("feed: a 200 writes one cache file per source", Set(first.updated) == Set(PriceSource.allCases) && cacheFiles(dir) == ["prices-litellm.json", "prices-modelsdev.json", "prices-openrouter.json"])
        installLocal(feed)
        check("feed: the cache is what the next start reads", price("acme/alpha-1")?.kind == .openrouter && price("beta-2")?.kind == .litellm
              && feed.loadLocal().origins[.openrouter] == .cache(t0))
        clock.advance(3600)
        let second = feed.refreshBlocking()
        check("feed: within 24 hours no request is made", fetcher.count() == 3 && Set(second.fresh) == Set(PriceSource.allCases) && !second.changed)
        clock.advance(24 * 3600)
        fetcher.script(.openrouter, .notModified)
        fetcher.script(.litellm, .notModified)
        fetcher.script(.modelsdev, .ok(modelsDevText.replacingOccurrences(of: "\"input\":5,\"output\":6", with: "\"input\":50,\"output\":60"), etag: "\"md-2\""))
        let third = feed.refreshBlocking()
        check("feed: after 24 hours the request carries If-None-Match", fetcher.count() == 6 && fetcher.lastEtag(.openrouter) == "\"or-1\"" && fetcher.lastEtag(.litellm) == "\"ll-1\""
              && fetcher.lastEtag(.modelsdev) == nil)
        check("feed: a 304 keeps the rows and renews the timestamp", Set(third.notModified) == [.openrouter, .litellm] && third.updated == [.modelsdev]
              && feed.loadLocal().origins[.openrouter] == .cache(clock.now) && price("acme/alpha-1", "")?.rates.input == 3)
        installLocal(feed)
        check("feed: a changed catalogue replaces the cache", price("md-only-9")?.kind == .modelsdev)
        clock.advance(25 * 3600)
        fetcher.script(.modelsdev, .notModified)
        _ = feed.refreshBlocking()
        check("feed: the ETag the server sent last is the one sent next", fetcher.lastEtag(.modelsdev) == "\"md-2\"" && fetcher.lastEtag(.openrouter) == "\"or-1\"")
        try? FileManager.default.removeItem(at: dir)
    }
    do { // stale cache + network down: the cache is used; failures back off for an hour
        let dir = tempDirectory(), clock = Clock(t0), fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(openRouterText, etag: nil))
        fetcher.script(.litellm, .ok(liteLLMText, etag: nil))
        fetcher.script(.modelsdev, .ok(modelsDevText, etag: nil))
        let feed = makeFeed(dir, fetcher, clock)
        _ = feed.refreshBlocking()
        clock.advance(30 * 24 * 3600)
        for s in PriceSource.allCases { fetcher.script(s, .fail) }
        let down = feed.refreshBlocking()
        installLocal(feed)
        check("feed: a month-old cache is still used when the network is down", down.failed.count == 3 && price("acme/alpha-1")?.kind == .openrouter
              && feed.loadLocal().origins[.openrouter] == .cache(t0))
        let calls = fetcher.count()
        clock.advance(600)
        let soon = feed.refreshBlocking()
        check("feed: after a failure the next try waits an hour", fetcher.count() == calls && Set(soon.skipped) == Set(PriceSource.allCases))
        clock.advance(3600)
        _ = feed.refreshBlocking()
        check("feed: and then tries again", fetcher.count() == calls + 3)
        try? FileManager.default.removeItem(at: dir)
    }
    do { // garbage and broken cache
        let dir = tempDirectory(), clock = Clock(t0), fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(openRouterText, etag: "\"or-1\""))
        fetcher.script(.litellm, .garbage)
        fetcher.script(.modelsdev, .ok("{\"data\": []}", etag: nil))
        let feed = makeFeed(dir, fetcher, clock)
        let report = feed.refreshBlocking()
        check("feed: an answer that is not the catalogue never reaches the cache", report.updated == [.openrouter] && Set(report.failed.keys) == [.litellm, .modelsdev]
              && cacheFiles(dir) == ["prices-openrouter.json"])
        clock.advance(25 * 3600)
        fetcher.script(.openrouter, .garbage)
        let again = feed.refreshBlocking()
        check("feed: garbage after a good answer leaves the old rows", again.failed[.openrouter] != nil && feed.loadLocal().origins[.openrouter] == .cache(t0))
        try? "not json at all".write(to: dir.appendingPathComponent("prices-litellm.json"), atomically: true, encoding: .utf8)
        try? "{\"schema\":1,\"source\":\"openrouter\",\"fetched\":1,\"rows\":{}}".write(to: dir.appendingPathComponent("prices-modelsdev.json"), atomically: true, encoding: .utf8)
        let local = feed.loadLocal()
        check("feed: a broken or foreign cache file is as good as none", local.origins[.litellm] == PriceCatalogs.embedded.origins[.litellm]
              && local.origins[.modelsdev] == PriceCatalogs.embedded.origins[.modelsdev])
        try? FileManager.default.removeItem(at: dir)
    }
    do { // offline: not one request
        let dir = tempDirectory(), clock = Clock(t0), fetcher = ScriptedFetcher()
        for s in PriceSource.allCases { fetcher.script(s, .ok(liteLLMText, etag: nil)) }
        let feed = makeFeed(dir, fetcher, clock, offline: true)
        let report = feed.refreshBlocking()
        check("feed: offline makes no request at all", fetcher.count() == 0 && Set(report.skipped) == Set(PriceSource.allCases) && cacheFiles(dir).isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
    do { // feeding from files
        let dir = tempDirectory(), feedDir = tempDirectory(), clock = Clock(t0)
        try? openRouterText.write(to: feedDir.appendingPathComponent("openrouter.json"), atomically: true, encoding: .utf8)
        try? liteLLMText.write(to: feedDir.appendingPathComponent("litellm.json"), atomically: true, encoding: .utf8)
        try? modelsDevText.write(to: feedDir.appendingPathComponent("modelsdev.json"), atomically: true, encoding: .utf8)
        let feed = makeFeed(dir, FilePriceFetcher(directory: feedDir), clock)
        let report = feed.refreshBlocking()
        installLocal(feed)
        check("feed: catalogues fed from files, no network", Set(report.updated) == Set(PriceSource.allCases) && price("eps-5")?.kind == .modelsdev && price("gamma-3")?.kind == .litellm)
        let litellmCache = (try? String(contentsOf: dir.appendingPathComponent("prices-litellm.json"), encoding: .utf8)) ?? ""
        // The cache keeps the winner of each key and the rows an exact id reaches with a price of their own (the Vertex
        // row of delta-4 has its own price): not the rows of other modes (embed-1) or the ones that price nothing.
        check("feed: the cache keeps only the rows a lookup can return", cacheFiles(dir).count == 3 && litellmCache.contains("\"delta-4\"")
              && litellmCache.contains("vertex_ai") && !litellmCache.contains("embed-1") && !litellmCache.contains("free-chat"))
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: feedDir)
    }

    // MARK: pinned mode and the offline switch

    check("pinned: this run reads neither a cache nor an alias file", PriceBook.isPinned)
    PriceBook.install(catalogs: .embedded)
    check("PriceBook.date is the snapshot's day", PriceBook.date == PriceCatalogs.embedded.date && PriceBook.date.count == 10)
}
