import Foundation

/// English readings of the source warnings the scanner and the index write in Turkish ("kaynak uyarıları").
///
/// The scanner's messages carry file names and numbers inside, so they are translated phrase by phrase: a
/// message this table does not know stays as written, which is Turkish and never wrong. Turkish interface
/// language shows every message untouched.
public enum IssueText {
    /// Longest phrase first, so a short one never eats part of a longer one.
    private static let phrases: [(tr: String, en: String)] = [
        ("zstd yok: brew install zstd (.jsonl.zst arşivleri okunamıyor)", "zstd is missing: brew install zstd (.jsonl.zst archives cannot be read)"),
        ("Dizin şeması", "Index schema"),
        (": dokunulmadı (", ": left untouched ("),
        (", beklenen ", ", expected "),
        ("geçerli bir JSON nesnesi değil", "not a valid JSON object"),
        ("dizisi yok", "array is missing"),
        ("nesne değil", "not an object"),
        ("yok ya da geçersiz (harf, rakam, . _ -)", "missing or invalid (letters, digits, . _ -)"),
        ("bilinmeyen aile ", "unknown family "),
        ("; bilinenler: ", "; known: "),
        ("boş ya da dizi değil", "empty or not an array"),
        ("ailesinin öneki ", "family's prefix is "),
        (" olamaz", " is not allowed"),
        ("küçük harf, rakam ve - olmalı", "must be lowercase letters, digits and -"),
        ("önekini ", "prefix is used by "),
        (" kullanıyor", ""),
        ("dosya kayıtları okunamadı", "the file records could not be read"),
        (" dosya atlandı)", " files skipped)"),
        ("SQLite açılamadı", "Could not open SQLite"),
        ("SQL hatası", "SQL error"),
        ("SQL hazırlanamadı", "SQL could not be prepared"),
        ("SQL adımı başarısız", "SQL step failed"),
        ("Veritabanı açılamadı", "Could not open the database"),
        ("kullanım alanları anlaşılmadı", "usage fields not understood"),
        (": adım ", ": step "),
    ]

    /// The message in the interface language.
    public static func localized(_ message: String) -> String {
        guard L10n.lang == .en else { return message }
        var out = message
        for (tr, en) in phrases { out = out.replacingOccurrences(of: tr, with: en) }
        return out
    }
}
