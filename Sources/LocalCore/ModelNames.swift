import Foundation

/// The lookup keys of one logged model name, most specific first. Swift twin of `Keys` in scripts/pricelib.py:
/// the oracle must fold names the same way, so a rule changes in both places or in none.
///
/// - `key1`: the name without provider path, region, `[1m]`-style marks, route tags (`:free`, `:batch`), dates
///   (`-20250929`, `@20250929`) and Bedrock versions (`-v1:0`), with `.`, `_` and `@` read as `-`
///   (so `claude-opus-4.6` and `claude-opus-4-6` meet). Still the model's own spelling.
/// - `key2`: `key1` without `-free`, `-thinking` and `-latest`.
/// - `quant`: `key2` without local quantisation or format suffixes (`-4bit`, `-q4_k_m`, `-mlx`, `-gguf`, `-dwq`,
///   `-awq` ...); nil when the name has none. A name with such a suffix is a local model.
public struct ModelKeys: Sendable, Equatable {
    public let key1: String
    public let key2: String
    public let quant: String?

    public var quantised: Bool { quant != nil }
    /// Keys the catalogues are asked, in order.
    public let ordered: [String]

    public init(_ model: String) {
        let ident = ModelNames.identity(ModelNames.clean(model))
        key1 = ModelNames.fold(ident)
        key2 = ModelNames.fold(ModelNames.variantFree(ident))
        let (stripped, found) = ModelNames.quantFree(ident)
        quant = found ? ModelNames.fold(ModelNames.variantFree(stripped)) : nil
        var list = [key1]
        if key2 != key1 { list.append(key2) }
        if let quant, !list.contains(quant) { list.append(quant) }
        ordered = list
    }
}

public enum ModelNames {
    static let regions = ["us", "eu", "apac", "global", "jp", "au", "ca", "us-gov"]
    static let vendors = ["anthropic", "meta", "amazon", "mistral", "cohere", "ai21", "deepseek", "openai", "qwen", "google",
                          "moonshotai", "moonshot", "minimax", "zai", "writer", "nvidia", "stability", "twelvelabs"]
    /// Route marks that never change the model: the bare name's row is the price.
    static let tags: Set<String> = ["free", "batch", "thinking", "extended", "nitro", "floor", "online", "exacto", "beta", "latest",
                                    "default", "flex", "priority", "standard"]
    /// Servers that run a model on this Mac (the user's own list adds to these).
    static let localProviders: Set<String> = ["ollama", "lmstudio", "lm-studio", "mlx", "omlx", "llama.cpp", "llamacpp", "llama-cpp",
                                              "local", "localhost", "jan", "gpt4all", "koboldcpp", "llamafile"]

    /// The longest model name that is normalised. The folding steps below walk a name more than once, so a name of
    /// hundreds of thousands of characters (a corrupt log line) would hold a scan for minutes; no real name is near this.
    static let maxNameLength = 256

    /// The first `maxNameLength` characters of a name.
    static func capped(_ model: String) -> String {
        guard model.utf8.count > maxNameLength else { return model }
        return String(model.prefix(maxNameLength))
    }

    /// `key1` alone: what a catalogue's ids are indexed by.
    static func key1(_ model: String) -> String { fold(identity(clean(model))) }

    /// The keys of a logged name.
    public static func keys(_ model: String) -> ModelKeys { ModelKeys(model) }

    /// Whether `provider` names a server on this Mac. `extra` is the user's own list.
    public static func isLocalProvider(_ provider: String, extra: Set<String> = []) -> Bool {
        let p = provider.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
        return localProviders.contains(p) || extra.contains(p)
    }

    /// The same spelling the provider list is compared in.
    static func providerKey(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
    }


    // MARK: Display names

    private static let acronyms: [String: String] = ["gpt": "GPT", "glm": "GLM", "oss": "OSS", "vl": "VL", "moe": "MoE", "llm": "LLM",
                                                     "ai": "AI", "ocr": "OCR", "asr": "ASR", "tts": "TTS", "cli": "CLI"]
    private static let brands: [String: String] = ["deepseek": "DeepSeek", "minimax": "MiniMax", "mimo": "MiMo", "longcat": "LongCat",
                                                   "sensenova": "SenseNova", "openai": "OpenAI", "qwen": "Qwen"]

    /// A name that came from a catalogue over the network, as the picture and `tokenbar-cli` may print it: without C0 and
    /// C1 control characters (an ESC would let a name move a terminal's cursor or set its title) and without the bidi
    /// overrides and isolates U+202A-202E and U+2066-2069, the left/right and Arabic letter marks U+200E, U+200F, U+061C (they would reorder the text around them) and the line and paragraph separators U+2028, U+2029. Everything else, a
    /// zero-width joiner and the Turkish letters included, stays.
    public static func displaySafe(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isUnsafeForDisplay($0) }) else { return text }
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars where !isUnsafeForDisplay(u) { scalars.append(u) }
        return String(scalars)
    }

    private static func isUnsafeForDisplay(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return v < 0x20 || (0x7F...0x9F).contains(v) || (0x200E...0x200F).contains(v) || v == 0x061C
            || v == 0x2028 || v == 0x2029 || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    /// A readable name for a catalogue id that has no name of its own: `claude-mythos-5-2` is "Claude Mythos 5.2",
    /// `gpt-6.2-sol` "GPT-6.2 Sol". The provider path, route tags and dates go; two small numbers in a row (or one
    /// after a letter-and-digit word such as `k3`) are a version, so `-` becomes `.`; a word with a digit is upper case
    /// (`27b` is "27B"). Only a name for the picture: it never takes part in a lookup.
    public static func display(_ model: String) -> String {
        var words = identity(clean(model)).split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard !words.isEmpty else { return model }
        func small(_ w: String) -> Bool { w.count <= 2 && !w.isEmpty && w.allSatisfy { $0.isASCII && $0.isNumber } }
        func hasDigit(_ w: String) -> Bool { w.contains { $0.isASCII && $0.isNumber } }
        var merged: [String] = []
        for w in words {
            if small(w), let last = merged.last, let end = last.last, end.isASCII, end.isNumber {
                merged[merged.count - 1] = last + "." + w
            } else {
                merged.append(w)
            }
        }
        words = merged
        func cased(_ w: String) -> String {
            if let a = acronyms[w] { return a }
            if let b = brands[w] { return b }
            // "27b", "a3b", "k3", "v4": a short word with a digit is a size or a version tag.
            if hasDigit(w) { return w.count <= 4 || w.first?.isNumber == true ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let c = cased(w)
            // "GPT-6.2": an acronym straight before its number keeps the dash.
            if i > 0, let last = out.last, acronyms[words[i - 1]] == "GPT", hasDigit(w), !w.contains(where: { $0.isLetter }) {
                out[out.count - 1] = last + "-" + c
            } else {
                out.append(c)
            }
        }
        return out.joined(separator: " ")
    }

    // MARK: Folding steps

    static func fold(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastDash = false
        for ch in s {
            let c: Character = (ch == "." || ch == "_" || ch == "@") ? "-" : ch
            if c == "-" {
                if lastDash { continue }
                lastDash = true
            } else {
                lastDash = false
            }
            out.append(c)
        }
        return out
    }

    /// `[1m]`, `(high)` and the like at the end. One backward pass over the characters (a name of many groups is not
    /// copied once per group).
    static func stripBrackets(_ input: String) -> String {
        let chars = Array(input.trimmingCharacters(in: .whitespaces))
        var end = chars.count
        func isSpace(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) } }
        while end > 0, chars[end - 1] == "]" || chars[end - 1] == ")" {
            let last = chars[end - 1]
            let open: Character = last == "]" ? "[" : "("
            // The first opener after the last closer: what `\[[^\]]*\]$` would take.
            var from = 0
            var i = end - 2
            while i >= 0 { if chars[i] == last { from = i + 1; break }; i -= 1 }
            guard from <= end - 2, let opener = chars[from..<(end - 1)].firstIndex(of: open) else { break }
            end = opener
            while end > 0, isSpace(chars[end - 1]) { end -= 1 }
        }
        return end == chars.count ? String(chars) : String(chars[0..<end])
    }

    /// Lowercase, no brackets, no provider path, no Bedrock region or vendor prefix.
    static func clean(_ model: String) -> String {
        var s = stripBrackets(capped(model).trimmingCharacters(in: .whitespaces).lowercased())
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let n = vendorPrefixLength(s) { return String(s.dropFirst(n)) }
        if let n = regionPrefixLength(s) { return String(s.dropFirst(n)) }
        return s
    }

    private static func isAlnumLower(_ c: Character) -> Bool { (c >= "a" && c <= "z") || (c >= "0" && c <= "9") }

    /// `(?:region\.)?vendor\.` followed by a letter or digit.
    static func vendorPrefixLength(_ s: String) -> Int? {
        func vendor(at offset: Int) -> Int? {
            let rest = s.dropFirst(offset)
            for v in vendors where rest.hasPrefix(v + ".") {
                let after = rest.dropFirst(v.count + 1)
                if let c = after.first, isAlnumLower(c) { return offset + v.count + 1 }
            }
            return nil
        }
        for r in regions where s.hasPrefix(r + ".") {
            if let n = vendor(at: r.count + 1) { return n }
        }
        return vendor(at: 0)
    }

    /// `region\.` followed by a letter.
    static func regionPrefixLength(_ s: String) -> Int? {
        for r in regions where s.hasPrefix(r + ".") {
            if let c = s.dropFirst(r.count + 1).first, c >= "a" && c <= "z" { return r.count + 1 }
        }
        return nil
    }

    private static func allDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// `-YYYYMMDD` or `-YYYY-MM-DD` at the end: the length to drop.
    private static func dateSuffixLength(_ s: String) -> Int? {
        if s.count > 9 {
            let tail = s.suffix(9)
            if tail.first == "-", allDigits(tail.dropFirst()), tail.count == 9 { return 9 }
        }
        if s.count > 11 {
            let tail = Array(s.suffix(11))
            if tail[0] == "-", tail[5] == "-", tail[8] == "-",
               allDigits(Substring(String(tail[1...4]))), allDigits(Substring(String(tail[6...7]))), allDigits(Substring(String(tail[9...10]))) {
                return 11
            }
        }
        return nil
    }

    /// `-v1:0` at the end (Bedrock's model version).
    static func dropBedrockVersion(_ s: String) -> String {
        guard let colon = s.lastIndex(of: ":"), let dash = s[..<colon].lastIndex(of: "-") else { return s }
        let version = s[s.index(after: dash)..<colon]
        let minor = s[s.index(after: colon)...]
        guard version.count > 1, version.first == "v", allDigits(version.dropFirst()), allDigits(minor) else { return s }
        return String(s[..<dash])
    }

    /// The name without route marks, dates and Bedrock versions: still the model's own spelling.
    static func identity(_ input: String) -> String {
        var s = input
        while true {
            let before = s
            if let at = s.lastIndex(of: "@") {
                let tail = s[s.index(after: at)...]
                if tail == "latest" || tail == "default" || (tail.count == 8 && allDigits(tail)) { s = String(s[..<at]) }
            }
            s = dropBedrockVersion(s)
            // A tag after the last colon: free, batch ...; anything else (an Ollama size) joins with a dash.
            if let colon = s.lastIndex(of: ":") {
                let tag = s[s.index(after: colon)...]
                if !tag.isEmpty, tag.allSatisfy({ isAlnumLower($0) || $0 == "_" || $0 == "." || $0 == "-" }) {
                    s = String(s[..<colon]) + (tags.contains(String(tag)) ? "" : "-" + tag)
                }
            }
            if let n = dateSuffixLength(s) { s = String(s.dropLast(n)) }
            if s == before { return s }
        }
    }

    /// `-free`, `-thinking`, `-latest` and a date, repeatedly.
    static func variantFree(_ input: String) -> String {
        var s = input
        while true {
            let before = s
            for suffix in ["-free", "-thinking", "-latest"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
            if let n = dateSuffixLength(s) { s = String(s.dropLast(n)) }
            if s == before { return s }
        }
    }

    /// `i?q\d+(_[a-z0-9]+)*`, `\d+bit` or one of the format words.
    private static func isQuantToken(_ t: Substring) -> Bool {
        if ["mlx", "gguf", "dwq", "awq", "gptq", "exl2"].contains(String(t)) { return true }
        if t.hasSuffix("bit"), allDigits(t.dropLast(3)) { return true }
        var rest = t
        if rest.first == "i" { rest = rest.dropFirst() }
        guard rest.first == "q" else { return false }
        rest = rest.dropFirst()
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        rest = rest.dropFirst(digits.count)
        if rest.isEmpty { return true }
        let pieces = rest.split(separator: "_", omittingEmptySubsequences: false)
        guard pieces.first == "" else { return false }
        return pieces.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy(isAlnumLower) }
    }

    /// (name without local quantisation or format suffixes, whether it had any)
    static func quantFree(_ input: String) -> (String, Bool) {
        var s = input
        var found = false
        while true {
            var cut: String.Index?
            for i in s.indices where s[i] == "-" || s[i] == "_" || s[i] == "." {
                if isQuantToken(s[s.index(after: i)...]) { cut = i; break }
            }
            guard let cut, cut != s.startIndex else { return (s, found) }
            s = String(s[..<cut])
            found = true
        }
    }

    /// The family proxy's step: the name without one trailing account number (3 or 4 digits), effort word or
    /// context size; nil when it has none.
    static func familyStripped(_ name: String) -> String? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let tail = name[name.index(after: dash)...]
        let isNumber = (tail.count == 3 || tail.count == 4) && allDigits(tail)
        let isContext = tail.count > 1 && tail.last == "k" && allDigits(tail.dropLast())
        guard isNumber || isContext || ["high", "medium", "low", "minimal", "xhigh", "max"].contains(String(tail)) else { return nil }
        return String(name[..<dash])
    }
}
