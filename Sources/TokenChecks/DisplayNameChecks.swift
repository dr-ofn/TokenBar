import Foundation
import LocalCore

// Display names: a catalogue row without a name (LiteLLM has none) shows a readable form of its id, never the raw id.
// The name is a label only: the price a model gets is the same with or without it.
func displayNameChecks() {
    let cases: [(String, String)] = [
        ("claude-mythos-5-2", "Claude Mythos 5.2"), ("gpt-6.2-sol", "GPT-6.2 Sol"), ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-6-luna", "GPT-6 Luna"), ("gemini-4-neon", "Gemini 4 Neon"), ("gemini-4-hydrogen", "Gemini 4 Hydrogen"),
        ("kimi-k3-1-pro", "Kimi K3.1 Pro"), ("glm-5-3-flash", "GLM 5.3 Flash"), ("deepseek-v4-flash", "DeepSeek V4 Flash"),
        ("openai/gpt-6.2-astra", "GPT-6.2 Astra"), ("nvidia/nemotron-3.5-super-vl:free", "Nemotron 3.5 Super VL"),
        ("qwen3-8-27b", "Qwen3.8 27B"), ("llama-3-1-70b-instruct", "Llama 3.1 70B Instruct"),
    ]
    let wrong = cases.filter { ModelNames.display($0.0) != $0.1 }.map { "\($0.0) -> \(ModelNames.display($0.0))" }
    check("display names: ids read as names (\(wrong.joined(separator: "; ")))", wrong.isEmpty)
    check("display names: an id with nothing to improve is only capitalised, an empty one stays", ModelNames.display("beam") == "Beam" && ModelNames.display("") == "")
    check("display names: a date stamp or route tag is not part of the name", ModelNames.display("claude-opus-5-5-20260101") == "Claude Opus 5.5"
          && ModelNames.display("acme/alpha-1:free") == "Alpha 1")

    let litellm = Data(#"{"acme/alpha-big-2-1": {"input_cost_per_token": 0.000001, "output_cost_per_token": 0.000002}}"#.utf8)
    PriceBook.install(catalogs: PriceCatalogs.fromRaw([.litellm: litellm]))
    let bare = ModelPrice(model: "alpha-big-2-1").entry
    check("display names: a LiteLLM row without a name shows the readable id, with the same price",
          bare?.name == "Alpha Big 2.1" && bare?.kind == .litellm && bare?.rates.input == 1 && bare?.rates.output == 2)
    let openrouter = Data(#"{"data":[{"id":"acme/alpha-big-2-1","name":"Acme: Alpha Big 2.1 (Preview)","pricing":{"prompt":"0.000009","completion":"0.000009"}}]}"#.utf8)
    PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: openrouter, .litellm: litellm]))
    let borrowed = ModelPrice(model: "alpha-big-2-1").entry
    check("display names: another catalogue's name for the same model is used, the price stays the first catalogue's",
          borrowed?.name == "Alpha Big 2.1 (Preview)" && borrowed?.rates.input == 9)
    PriceBook.install(catalogs: .embedded)
    let mythos = ModelPrice(model: "claude-mythos-5-2").entry
    check("display names: the embedded snapshot's bare ids are not shown raw", mythos != nil && mythos?.name != "claude-mythos-5-2" && mythos?.name.contains(" ") == true)
}
