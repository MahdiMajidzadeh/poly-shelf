import Foundation

/// Keyword→tag dictionary (FR-5.1). Ships as an editable JSON resource; a
/// user copy in Application Support (tag-dictionary.json) is merged over the
/// shipped defaults, so users can add languages/keywords without an update.
public struct TagDictionary: Sendable {
    public let keywords: [String: String]

    struct FileFormat: Decodable {
        let version: Int
        let keywords: [String: String]
    }

    public init(keywords: [String: String]) {
        self.keywords = keywords
    }

    public static func load(userOverrideDirectory: URL? = nil) -> TagDictionary {
        var merged: [String: String] = [:]
        if let url = shippedDictionaryURL(),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(FileFormat.self, from: data) {
            merged = parsed.keywords
        }
        if let dir = userOverrideDirectory {
            let userURL = dir.appendingPathComponent("tag-dictionary.json")
            if let data = try? Data(contentsOf: userURL),
               let parsed = try? JSONDecoder().decode(FileFormat.self, from: data) {
                merged.merge(parsed.keywords) { _, user in user }
            }
        }
        return TagDictionary(keywords: Dictionary(
            uniqueKeysWithValues: merged.map { ($0.key.lowercased(), $0.value) }
        ))
    }

    /// Locates the shipped dictionary without `Bundle.module`, whose generated
    /// accessor fatalErrors when the resource bundle isn't exactly where that
    /// toolchain expects (it also skips Contents/Resources in SwiftPM-built
    /// .app bundles). Never crashes — a missing bundle just means no keyword
    /// tags until the user provides an override.
    static func shippedDictionaryURL() -> URL? {
        let bundleName = "PolyShelfCore_PolyShelfCore.bundle"
        var candidates = [
            Bundle.main.resourceURL,                       // .app Contents/Resources
            Bundle.main.bundleURL,                         // .app root / executable dir
            Bundle(for: BundleToken.self).resourceURL,     // host bundle (tests)
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        candidates.append(contentsOf: candidates.compactMap { $0 }) // stable order; dedupe below
        var seen = Set<String>()
        for candidate in candidates {
            guard let dir = candidate, seen.insert(dir.path).inserted else { continue }
            let bundleURL = dir.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "tag-dictionary", withExtension: "json") {
                return url
            }
        }
        // Direct hit (tests, odd layouts): the json sitting next to a candidate.
        for candidate in candidates {
            guard let dir = candidate else { continue }
            let url = dir.appendingPathComponent("tag-dictionary.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Tokenizes a filename or folder name: splits on separators and
    /// camelCase, lowercases, and adds joined 2-/3-grams so multi-word
    /// keywords ("print-in-place") match regardless of separator style.
    public static func tokenize(_ name: String) -> [String] {
        // Insert breaks at camelCase boundaries before splitting.
        var expanded = ""
        var previous: Character?
        for ch in name {
            if let prev = previous, prev.isLowercase, ch.isUppercase {
                expanded.append(" ")
            }
            expanded.append(ch)
            previous = ch
        }
        let raw = expanded
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var tokens = raw
        // Joined n-grams: "print in place" → "printinplace", "print-in-place"
        for n in 2...3 where raw.count >= n {
            for i in 0...(raw.count - n) {
                let gram = raw[i..<(i + n)]
                tokens.append(gram.joined())
                tokens.append(gram.joined(separator: "-"))
            }
        }
        return tokens
    }

    /// Tags matched from a filename plus its parent folder names.
    public func matchTags(filename: String, parentFolders: [String]) -> Set<String> {
        var tokens = Self.tokenize((filename as NSString).deletingPathExtension)
        for folder in parentFolders {
            tokens.append(contentsOf: Self.tokenize(folder))
        }
        var tags: Set<String> = []
        for token in tokens {
            if let tag = keywords[token] {
                tags.insert(tag)
            }
        }
        return tags
    }
}

/// Anchor for Bundle(for:) lookups in shippedDictionaryURL().
private final class BundleToken {}
