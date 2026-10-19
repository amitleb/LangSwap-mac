// LangSwap — type Hebrew or English without switching the keyboard (macOS menu-bar app).
// MIT License. See README.md.
//
// Works word by word: it finds the trailing run of words that are wrong in the
// current layout but right in the other one, and converts only that run.
// Typos and misplaced spaces in the converted text are fixed when possible.
// Cmd+Z right after a fix = undo. Double-tap Shift = convert the last words by hand.

import AppKit
import Carbon
import ServiceManagement
import ApplicationServices

let kMagic: Int64 = 0x4C5357          // tags events we post ourselves
let hebFinals: Set<Character> = ["ך", "ם", "ן", "ף", "ץ"]
let trimSet = CharacterSet(charactersIn: "?!.,:;/\"()[]{}<>-–—…")

struct Key {
    let code: UInt16; let shift: Bool; let caps: Bool
    var heb: Bool                      // layout this key was shown in
    var isSpace: Bool { code == 49 }
}

// MARK: - Keyboard layout wrapper

final class Layout {
    let source: TISInputSource
    let id: String
    let isHebrew: Bool
    private let data: Data
    private var reverse: [Character: Key] = [:]

    init?(_ s: TISInputSource, hebrew: Bool) {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
        source = s
        id = sourceID(s)
        isHebrew = hebrew
        for shift in [false, true] {
            for code in UInt16(0)..<UInt16(51) {
                let str = translate(code, shift: shift, caps: false)
                if str.count == 1, let c = str.first, reverse[c] == nil {
                    reverse[c] = Key(code: code, shift: shift, caps: false, heb: hebrew)
                }
            }
        }
    }

    func char(_ k: Key) -> String {
        let s = translate(k.code, shift: k.shift, caps: k.caps)
        // On the Mac Hebrew layout Shift/Caps on a letter key gives a Latin capital.
        // When converting TO Hebrew we want the Hebrew letter instead.
        if isHebrew, k.shift || k.caps,
           let u = s.unicodeScalars.first, s.unicodeScalars.count == 1,
           u.isASCII, CharacterSet.letters.contains(u) {
            return translate(k.code, shift: false, caps: false)
        }
        return s
    }

    func key(for ch: Character) -> Key? { reverse[ch] }

    func translate(_ code: UInt16, shift: Bool, caps: Bool) -> String {
        var dead: UInt32 = 0
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var mods: UInt32 = 0
        if shift { mods |= UInt32(shiftKey >> 8) }
        if caps { mods |= UInt32(alphaLock >> 8) }
        let st: OSStatus = data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(ptr, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return st == noErr ? String(utf16CodeUnits: chars, count: len) : ""
    }
}

func sourceID(_ s: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func isASCIICapable(_ s: TISInputSource) -> Bool {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsASCIICapable) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}

/// Edit distance where swapping two neighbour letters counts as one edit.
func osa(_ a: [Character], _ b: [Character]) -> Int {
    if abs(a.count - b.count) > 1 { return 2 }
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { d[i][0] = i }
    for j in 0...b.count { d[0][j] = j }
    for i in 1...a.count { for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
        if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
    } }
    return d[a.count][b.count]
}


// MARK: - Speller: typo fixing from word-frequency lists (FrequencyWords, MIT, Hermit Dave)

final class Speller {
    // Letters are stored as small codes; costs are in tenths (10 = one full edit).
    struct Entry { let c: [UInt8]; let s: String; let lf: Double; let mask: UInt64 }
    let heb: Bool
    private(set) var byLen: [Int: [Entry]] = [:]
    private(set) var freq: [String: Int] = [:]
    private var code: [Character: UInt8] = [:]
    private var chars: [Character] = []
    private var adjT = [Bool](repeating: false, count: 64 * 64)
    private var finT = [Bool](repeating: false, count: 64 * 64)
    private var r0 = [Int](repeating: 0, count: 64), r1 = [Int](repeating: 0, count: 64), r2 = [Int](repeating: 0, count: 64)

    static var pos: [Character: (Double, Double)] = {
        let rows = ["qwertyuiop", "asdfghjkl;", "zxcvbnm,."]
        let hebKeys = Array("/׳קראטוןםפשדגכעיחלךףזסבהנמצתץ")
        var p: [Character: (Double, Double)] = [:]
        var n = 0
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                let v = (Double(r), Double(c) + 0.5 * Double(r))
                p[ch] = v; p[hebKeys[n]] = v; n += 1
            }
        }
        return p
    }()
    static let finals: [Character: Character] = ["ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ"]

    init?(path: String, heb: Bool) {
        self.heb = heb
        let alphabet: [Character] = heb ? Array("אבגדהוזחטיךכלםמןנסעףפץצקרשת") : Array("abcdefghijklmnopqrstuvwxyz")
        for c in alphabet { code[c] = UInt8(chars.count); chars.append(c) }
        for a in chars { for b in chars {
            adjT[Int(code[a]!) * 64 + Int(code[b]!)] = Speller.adjacent(a, b)
            finT[Int(code[a]!) * 64 + Int(code[b]!)] = Speller.finals[a] == b || Speller.finals[b] == a
        } }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let f = Int(parts[1]), f >= 30 else { continue }
            let w = String(parts[0])
            guard w.count >= 2, let c = encode(w) else { continue }
            freq[w] = f
            byLen[c.count, default: []].append(Entry(c: c, s: w, lf: log10(Double(f)), mask: maskOf(c)))
        }
    }

    static func adjacent(_ a: Character, _ b: Character) -> Bool {
        guard let p = pos[a], let q = pos[b] else { return false }
        return abs(p.0 - q.0) <= 1 && abs(p.1 - q.1) <= 1.01
    }
    func adj(_ a: Character, _ b: Character) -> Bool { Speller.adjacent(a, b) }

    func encode(_ w: String) -> [UInt8]? {
        var out: [UInt8] = []
        for ch in w { guard let c = code[ch] else { return nil }; out.append(c) }
        return out
    }
    func maskOf(_ c: [UInt8]) -> UInt64 { c.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) } }

    /// Typo cost in tenths: neighbour keys, swapped letters, doubled letters are cheap.
    func cost(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        let n = a.count, m = b.count
        for j in 0...m { r1[j] = j * 10 }
        for i in 1...n {
            r0[0] = i * 10
            var rowMin = r0[0]
            let ai = Int(a[i - 1])
            let del = (i > 1 && (a[i - 1] == a[i - 2] || adjT[ai * 64 + Int(a[i - 2])])) ? 6 : 10
            for j in 1...m {
                let bj = Int(b[j - 1])
                let ins = (j > 1 && b[j - 1] == b[j - 2]) ? 6 : 10
                // final/regular mix-up (שלומ -> שלום) is cheap only at the end of the word;
                // a final letter in the middle is a slip to a neighbour key (יםה -> יפה).
                let sub = ai == bj ? 0 : ((finT[ai * 64 + bj] && i == n && j == m) ? 3 : (adjT[ai * 64 + bj] ? 6 : 10))
                var v = min(r1[j] + del, r0[j - 1] + ins, r1[j - 1] + sub)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, r2[j - 2] + 5) }
                r0[j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > limit + 5 { return limit + 10 }
            swap(&r2, &r1); swap(&r1, &r0)
        }
        return r1[m]
    }

    /// How much more likely the best fix must be than the next one (Hebrew list is noisier).
    lazy var margin: Double = heb ? (Double(ProcessInfo.processInfo.environment["LSHEM"] ?? "") ?? 1.35) : 1.3

    /// Best fix for a misspelled word, or nil if not clearly one word.
    func best(_ w: String) -> String? {
        guard let a = encode(w), a.count >= 3, a.count < 60 else { return nil }
        let limit = a.count < 6 ? 10 : 16
        let ma = maskOf(a)
        var top: (Double, String) = (-.infinity, ""), second = -Double.infinity
        for len in max(2, a.count - 2)...(a.count + 2) {
            for e in byLen[len] ?? [] {
                if (ma ^ e.mask).nonzeroBitCount > 4 || e.s == w { continue }   // too many different letters
                let k = cost(a, e.c, limit: limit)
                guard k <= limit else { continue }
                let score = e.lf - 0.3 * Double(k)
                if score > top.0 { second = top.0; top = (score, e.s) } else if score > second { second = score }
            }
        }
        if Engine.debug { print(String(format: "   speller %@: best %@ %.2f, next %.2f", w, top.1, top.0, second)) }
        guard !top.1.isEmpty, top.0 - second >= margin else { return nil }
        return top.1
    }

    static let contractions: [String: String] = ["dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "isnt": "isn't",
        "arent": "aren't", "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't", "im": "I'm", "ive": "I've", "youre": "you're",
        "theyre": "they're", "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's", "whos": "who's",
        "youve": "you've", "weve": "we've", "theyve": "they've", "youll": "you'll", "theyll": "they'll", "cant": "can't",
        "wont": "won't", "lets": "let's", "itll": "it'll", "shes": "she's", "hes": "he's"]
}

// MARK: - Engine

final class Engine {
    var en: Layout?
    var he: Layout?
    var enabled = true
    var fixSpelling = true
    var autoCorrect = true
    var spellers: [Bool: Speller] = [:]
    var ignoreWords: Set<String> = []          // words you undid a fix for: never fix again
    var onIgnore: ((Set<String>) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var currentHebForBadge: Bool? { queryLayout() }
    var hotkey = true
    var excluded: Set<String> = []
    var frontBundle: String?
    var tap: CFMachPort?

    // test hooks
    var sync = false
    var queryLayout: (() -> Bool?)!
    var output: ((Int, String, Bool?) -> Void)!     // (backspaces, text, switch layout to Hebrew?)
    var pending: [() -> Void] = []

    private(set) var keys: [Key] = []
    var curHeb = false
    private var lockedBefore = 0         // words starting before this index are left alone
    private var bufferFresh = true       // buffer starts at a real start (not trimmed)
    struct Swap { let start: Int; let end: Int; let oldKeys: [Key]; let oldHeb: Bool; var refined = false; var typoOf: String? = nil }
    private(set) var lastSwap: Swap?
    private(set) var swapping = false
    var ignoreLayoutUntil = Date.distantPast

    private var cache: [String: Bool] = [:]
    private let spell = NSSpellChecker.shared
    private let src: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = kMagic
        return s
    }()
    // Keys that move the cursor or end the input -> forget the buffer.
    private let resetCodes: Set<UInt16> = [36, 76, 48, 53, 117, 115, 116, 119, 121, 123, 124, 125, 126]

    init() {
        queryLayout = { [unowned self] in self.systemHeb() }
        output = { [unowned self] del, text, heb in
            self.postBackspaces(del)
            self.postText(text)
            if let h = heb { self.select(self.layout(h)) }
        }
    }

    func loadLayouts() {
        en = nil; he = nil
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        var enCandidates: [TISInputSource] = []
        for s in list {
            let id = sourceID(s).lowercased()
            if id.contains("hebrew") {
                if he == nil { he = Layout(s, hebrew: true) }
            } else if isASCIICapable(s) {
                enCandidates.append(s)
            }
        }
        let preferred = enCandidates.first { ["com.apple.keylayout.abc", "com.apple.keylayout.us"].contains(sourceID($0).lowercased()) }
        if let s = preferred ?? enCandidates.first { en = Layout(s, hebrew: false) }
    }

    var ready: Bool { en != nil && he != nil }

    func loadSpellers(dir: String) {
        for (f, h) in [("en_50k.txt", false), ("he_50k.txt", true)] {
            if let sp = Speller(path: (dir as NSString).appendingPathComponent(f), heb: h) { spellers[h] = sp }
        }
    }

    func warmUp() { _ = isWord("שלום", heb: true); _ = isWord("hello", heb: false) }

    func reset() {
        keys.removeAll(keepingCapacity: true)
        lockedBefore = 0
        lastSwap = nil
        bufferFresh = true
    }

    private func systemHeb() -> Bool? {
        guard let en = en, let he = he,
              let cur = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let id = sourceID(cur)
        if id == he.id { return true }
        if id == en.id { return false }
        return nil
    }

    func layout(_ heb: Bool) -> Layout { heb ? he! : en! }
    func ch(_ k: Key, as heb: Bool? = nil) -> String { layout(heb ?? k.heb).char(k) }
    func text(_ r: Range<Int>, as heb: Bool? = nil) -> String { keys[r].map { ch($0, as: heb) }.joined() }
    var screenText: String { text(0..<keys.count) }

    private func schedule(_ f: @escaping () -> Void) {
        if sync { pending.append(f) } else { DispatchQueue.main.async(execute: f) }
    }

    // MARK: words

    struct Word { let r: Range<Int>; let heb: Bool }

    func words(upTo end: Int, includeLast: Bool) -> [Word] {
        var res: [Word] = []
        var s = 0
        for i in 0..<end where keys[i].isSpace {
            if i > s { res.append(Word(r: s..<i, heb: keys[s].heb)) }
            s = i + 1
        }
        if includeLast, end > s { res.append(Word(r: s..<end, heb: keys[s].heb)) }
        return res
    }

    struct Info { let letters: Int; let valid: Bool; var neutral: Bool { letters < 2 } }

    func core(_ s: String) -> String { s.trimmingCharacters(in: trimSet) }

    func info(_ s: String, heb: Bool) -> Info {
        let w = core(s)
        if w.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return Info(letters: 0, valid: true) }
        // A lone final letter ("ן" = the "i" key) is never a Hebrew word: count it as a wrong word.
        if heb, w.count == 1, let c = w.first, hebFinals.contains(c) { return Info(letters: 2, valid: false) }
        return Info(letters: w.count, valid: w.count >= 2 && isWord(w, heb: heb))
    }

    func isWord(_ w: String, heb: Bool) -> Bool {
        let k = (heb ? "h:" : "e:") + w
        if let v = cache[k] { return v }
        let v = shapeOK(w, heb: heb) && spellOK(w, lang: heb ? "he" : "en")
        if cache.count > 5000 { cache.removeAll() }
        cache[k] = v
        return v
    }

    func spellOK(_ w: String, lang: String) -> Bool {
        let r = spell.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                    inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }

    func shapeOK(_ w: String, heb: Bool) -> Bool {
        if heb {
            let chars = Array(w)
            let allHeb = w.unicodeScalars.allSatisfy { (0x05D0...0x05EA).contains($0.value) || $0.value == 0x05F3 || $0.value == 0x05F4 || $0 == "'" || $0 == "\"" }
            guard allHeb, let first = w.unicodeScalars.first, (0x05D0...0x05EA).contains(first.value) else { return false }
            if chars.dropLast().contains(where: { hebFinals.contains($0) }) { return false }   // final letter mid-word
            // geresh (׳) is only real after ג ז צ ץ ת. Elsewhere it is the English "w" key.
            if chars.enumerated().contains(where: { i, c in c == "׳" && (i == 0 || !"גזצץת".contains(chars[i - 1])) }) { return false }
            return true
        }
        return w.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.letters.contains($0)) || $0 == "'" }
    }

    // MARK: spelling fixes (only on text we are converting anyway)

    /// Split a word into two real words ("מהאתה" -> "מה אתה").
    // The spell checker accepts many odd 2-letter strings, so 2-letter parts must be common words.
    static let short2: Set<String> = ["מה", "את", "על", "זה", "לא", "כן", "אם", "גם", "של", "עם", "רק", "יש", "אז",
        "הם", "הן", "מי", "כי", "או", "די", "בו", "לו", "לי", "לך", "בה", "לה", "שם", "פה", "אף", "עד", "אל", "אך",
        "of", "to", "in", "is", "it", "be", "as", "at", "so", "we", "he", "by", "or", "on", "do", "if", "me", "my",
        "up", "an", "go", "no", "us", "am"]

    func split2(_ s: String, heb: Bool) -> String? {
        let c = Array(s)
        guard c.count >= 4 else { return nil }
        func ok(_ w: String) -> Bool { (w.count > 2 || Engine.short2.contains(w.lowercased())) && isWord(w, heb: heb) }
        for i in 2...(c.count - 2) {
            let a = String(c[..<i]), b = String(c[i...])
            if ok(a), ok(b) { return a + " " + b }
        }
        return nil
    }

    func correct(_ w: String, heb: Bool) -> String? {
        if !heb, let k = Speller.contractions[w.lowercased()] { return k }
        guard w.count >= 3, shapeOK(w, heb: heb) || !heb else { return nil }
        if let sp = spellers[heb] {
            if let b = sp.best(heb ? w : w.lowercased()), isWord(b, heb: heb) { return b }
            return nil
        }
        let lang = heb ? "he" : "en"
        let r = NSRange(location: 0, length: (w as NSString).length)
        if let c = spell.correction(forWordRange: r, in: w, language: lang, inSpellDocumentWithTag: 0),
           osa(Array(c), Array(w)) <= 1, isWord(c, heb: heb) { return c }
        guard w.count >= 4 else { return nil }
        let g = spell.guesses(forWordRange: r, in: w, language: lang, inSpellDocumentWithTag: 0) ?? []
        return g.first { osa(Array($0), Array(w)) <= 1 && isWord($0, heb: heb) }
    }

    struct Tok { var lead: String; var core: String; var trail: String
        var str: String { lead + core + trail } }

    func tok(_ s: String) -> Tok {
        let c = core(s)
        guard !c.isEmpty, let r = s.range(of: c) else { return Tok(lead: s, core: "", trail: "") }
        return Tok(lead: String(s[..<r.lowerBound]), core: c, trail: String(s[r.upperBound...]))
    }

    /// Returns the fixed text for token `t` (maybe merged with `next`), and whether `next` was used.
    func fix(_ t: Tok, next: Tok?, heb: Bool) -> (String, Bool)? {
        if let n = next, t.trail.isEmpty, n.lead.isEmpty, !n.core.isEmpty,
           !isWord(n.core, heb: heb) || n.core.count <= 2,
           let s = split2(t.core + n.core, heb: heb) {
            return (t.lead + s + n.trail, true)                       // misplaced space
        }
        if let s = split2(t.core, heb: heb) { return (t.lead + s + t.trail, false) }   // missing space
        if let c = correct(t.core, heb: heb) { return (t.lead + c + t.trail, false) }  // typo
        return nil
    }

    func fixText(_ s: String, heb: Bool) -> String {
        let parts = s.split(separator: " ", omittingEmptySubsequences: false).map { tok(String($0)) }
        var out: [String] = []
        var i = 0
        while i < parts.count {
            var t = parts[i]
            if !heb, t.core == "i" { t.core = "I" }
            // A lone letter after a word is almost always a misplaced space: "מהאת ה" -> "מה אתה".
            if heb, i + 1 < parts.count, t.core.count >= 2, t.trail.isEmpty {
                let n = parts[i + 1]
                if n.core.count == 1, n.lead.isEmpty, let s = split2(t.core + n.core, heb: heb) {
                    out.append(t.lead + s + n.trail); i += 2; continue
                }
            }
            if t.core.count >= 2, !isWord(t.core, heb: heb) {
                let next = i + 1 < parts.count ? parts[i + 1] : nil
                if let (f, used) = fix(t, next: next, heb: heb) {
                    out.append(f); i += used ? 2 : 1; continue
                }
            }
            out.append(t.str); i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: detection

    struct Run {
        let start: Int; let target: Bool
        let n: Int; let wrong: Int; let exact: Int; let fixable: Int; let letters: Int
        let firstWord: Bool; let soloCur: String; let soloAlt: String
    }

    func findRun(upTo end: Int, includeLast: Bool) -> Run? {
        let ws = words(upTo: end, includeLast: includeLast).filter { $0.r.lowerBound >= lockedBefore }
        guard let last = ws.last else { return nil }
        let heb = last.heb
        guard let (s, ext) = scanBack(ws, heb: heb) else { return nil }
        var n = 0, wrong = 0, exact = 0, fixable = 0, letters = 0
        var soloCur = "", soloAlt = ""
        for j in s..<ws.count {
            let w = ws[j]
            let curS = text(w.r), altS = text(w.r, as: !heb)
            let cur = info(curS, heb: heb), alt = info(altS, heb: !heb)
            if cur.neutral && alt.neutral { continue }
            n += 1; letters += alt.letters; soloCur = curS; soloAlt = altS
            if cur.neutral || !cur.valid { wrong += 1 }
            if alt.valid { exact += 1 }
            else if fixSpelling {
                let next = j + 1 < ws.count ? tok(text(ws[j + 1].r, as: !heb)) : nil
                if fix(tok(altS), next: next, heb: !heb) != nil { fixable += 1 }
            }
        }
        let firstWord = bufferFresh && lockedBefore == 0 && ext == 0
        return Run(start: ws[ext].r.lowerBound, target: !heb, n: n, wrong: wrong, exact: exact,
                   fixable: fixable, letters: letters, firstWord: firstWord, soloCur: soloCur, soloAlt: soloAlt)
    }

    /// Walk back from the last word over words that are wrong in their layout.
    /// Returns (first wrong word, start to convert). Short words that are real in BOTH
    /// languages ("to" = "אם", "tbh" = "אני") join the run only when nothing real comes
    /// before them (start of text), never after a normal word like "want".
    func scanBack(_ ws: [Word], heb: Bool) -> (Int, Int)? {
        var startIdx: Int?
        var amb: Int?
        var i = ws.count - 1
        var hitReal = false
        while i >= 0 {
            let w = ws[i]
            if w.heb != heb { break }
            let cur = info(text(w.r), heb: heb), alt = info(text(w.r, as: !heb), heb: !heb)
            if cur.neutral && alt.neutral { i -= 1; continue }                       // "-", "1", "a"
            if cur.neutral || !cur.valid { startIdx = i; amb = nil; i -= 1; continue } // wrong here
            if alt.valid && cur.letters <= 3 { if startIdx != nil { amb = i }; i -= 1; continue }
            hitReal = true; break                                                    // a real word: stop
        }
        guard let s = startIdx else { return nil }
        if !hitReal, let a = amb { return (s, a) }
        // Mid-sentence: still take short words right before the run when they are far more
        // common in the other language ("tbh" -> "אני" is ~10,000x more common than "tbh").
        var ext = s
        var j = s - 1
        while j >= 0 {
            let w = ws[j]
            if w.heb != heb { break }
            let cs = core(text(w.r)), as_ = core(text(w.r, as: !heb))
            let cur = info(cs, heb: heb), alt = info(as_, heb: !heb)
            if cur.neutral && alt.neutral { j -= 1; continue }
            guard alt.valid, cur.letters <= 3,
                  let fc = spellers[heb]?.freq[heb ? cs : cs.lowercased()].map(Double.init) ?? Optional(1.0),
                  let fa = spellers[!heb]?.freq[heb ? as_.lowercased() : as_].map(Double.init),
                  log10(fa) - log10(max(fc, 1)) >= 1.5 else { break }
            ext = j; j -= 1
        }
        return (s, ext)
    }

    static var minSingleWord = 5

    func shouldSwap(_ r: Run) -> Bool {
        if r.n == 1 {
            // One word alone: only as the first word, only if it is an exact word, 4+ letters.
            return r.firstWord && r.wrong == 1 && r.exact == 1 && r.letters >= Engine.minSingleWord
                && singleWordOK(r.soloCur, r.soloAlt, !r.target)
        }
        guard r.n >= 2, r.letters >= 5 else { return false }
        return r.wrong * 4 >= r.n * 3                     // 75%+ wrong where they are
            && r.exact * 2 >= r.n                         // 50%+ real words in the other language
            && (r.exact >= min(r.n, 2)                    // and at least 2 of them (all, if only 2 words)
                || (r.wrong == r.n && r.exact + r.fixable == r.n && r.letters >= 8))   // all wrong, all fixable, long
            && (r.exact + r.fixable) * 4 >= r.n * 3       // 75%+ real or fixable there
    }

    /// Extra safety for the one-word rule.
    func singleWordOK(_ current: String, _ alt: String, _ currentHeb: Bool) -> Bool {
        let a = alt.trimmingCharacters(in: .whitespaces)
        guard let f = a.unicodeScalars.first, CharacterSet.letters.contains(f) else { return false } // ",near"
        if currentHeb, !a.lowercased().contains(where: { "aeiouy".contains($0) }) { return false }   // "xcvc"
        let c = core(current.trimmingCharacters(in: .whitespaces))
        if c.count < 6 { return true }
        let lang = currentHeb ? "he" : "en"
        let r = NSRange(location: 0, length: (c as NSString).length)
        let g = spell.guesses(forWordRange: r, in: c, language: lang, inSpellDocumentWithTag: 0) ?? []
        return !g.contains { osa(Array($0.lowercased()), Array(c.lowercased())) <= 1 }   // looks like a plain typo
    }

    func check(upTo end: Int, includeLast: Bool) {
        guard enabled, ready, !swapping, keys.count >= end else { return }
        if refineAfterSwap(upTo: end, includeLast: includeLast) { return }
        let r = findRun(upTo: end, includeLast: includeLast)
        if let r = r {
            log("check \"\(text(0..<min(end, keys.count)))\" run n=\(r.n) wrong=\(r.wrong) exact=\(r.exact) fixable=\(r.fixable) letters=\(r.letters) first=\(r.firstWord) -> \(shouldSwap(r) ? "SWAP" : "no")")
        } else { log("check \"\(text(0..<min(end, keys.count)))\": no wrong words (locked before \(lockedBefore))") }
        if let r = r, shouldSwap(r) {
            convert(from: r.start, target: r.target, fixUpTo: end); return
        }
        fixLastTypo(upTo: end, includeLast: includeLast)
    }

    /// Same-language typo fix for the word just finished ("speling " -> "spelling ").
    func fixLastTypo(upTo end: Int, includeLast: Bool) {
        guard autoCorrect else { return }
        let ws = words(upTo: end, includeLast: includeLast).filter { $0.r.lowerBound >= lockedBefore }
        guard let last = ws.last else { return }
        // A word held back last time (it might have been the wrong keyboard) is fixed now,
        // once the next word shows we really are in this language.
        if ws.count >= 2 {
            let prev = ws[ws.count - 2]
            let lc = core(text(last.r)), la = core(text(last.r, as: !last.heb))
            if prev.heb == last.heb, lc.count >= 2, isWord(lc, heb: last.heb), !isWord(la, heb: !last.heb),
               tryFix(prev, careful: false) { return }
        }
        _ = tryFix(last, careful: true)
    }

    static let debug = ProcessInfo.processInfo.environment["LSDEBUG"] != nil
    var logUntil = Date.distantPast
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LangSwap.log")
    func log(_ m: @autoclosure () -> String) {
        if Engine.debug { print("   " + m()) }
        guard Date() < logUntil else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) [\(frontBundle ?? "?")] \(m())\n"
        if let h = try? FileHandle(forWritingTo: Engine.logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: Engine.logURL, atomically: true, encoding: .utf8) }
    }

    private func tryFix(_ w: Word, careful: Bool) -> Bool {
        let heb = w.heb
        let t = tok(text(w.r))
        let c = t.core
        func no(_ why: String) -> Bool { log("typo? \(c): \(why)"); return false }
        guard c.count >= 2 else { return false }
        if ignoreWords.contains(c.lowercased()) { return no("you undid this one before") }
        if isWord(c, heb: heb) { return false }
        // A final letter in the middle ("יםה") is itself a typo sign: ם and פ are neighbour keys.
        let hebLetters = heb && c.unicodeScalars.allSatisfy { (0x05D0...0x05EA).contains($0.value) }
        guard shapeOK(c, heb: heb) || hebLetters else { return no("not a plain word") }
        if !heb, c != c.lowercased() { return no("has capitals (name/brand)") }
        if careful {
            let alt = core(text(w.r, as: !heb))
            if alt.count >= 2, isWord(alt, heb: !heb) { return no("real word in other keyboard: wait") }
            if alt.count >= 2, (spellers[!heb]?.freq[alt.lowercased()] ?? 0) >= 1000 { return no("common word in other keyboard: wait") }
            if heb, Speller.contractions[alt.lowercased()] != nil { return no("contraction in other keyboard: wait") }
            if alt.count >= 3, spellers[!heb]?.best(alt) != nil { return no("close to a word in other keyboard: wait") }
        }
        var fixed: String?
        if !heb, let k = Speller.contractions[c], isWord(k, heb: false) { fixed = k }
        else if c.count >= 3, let sp = spellers[heb], let b = sp.best(c), isWord(b, heb: heb) { fixed = b }
        guard let f = fixed else { return no("no clear fix") }
        let newWord = t.lead + f + t.trail
        let L = layout(heb)
        let nk = newWord.compactMap { ch -> Key? in guard var k = L.key(for: ch) else { return nil }; k.heb = heb; return k }
        guard nk.count == newWord.count else { return no("cannot type fix") }
        let start = w.r.lowerBound
        let tail = Array(keys[w.r.upperBound...])
        let oldKeys = Array(keys[start...])
        swapping = true
        output(keys.count - start, newWord + tail.map { ch($0) }.joined(), nil)
        keys.replaceSubrange(start..., with: nk + tail)
        lastSwap = Swap(start: start, end: keys.count, oldKeys: oldKeys, oldHeb: heb, refined: true, typoOf: c.lowercased())
        lockedBefore = start + nk.count
        endSwapping(oldKeys.count + nk.count + tail.count)
        return true
    }

    /// After a fix, look once more when the next word is done: the space may have been
    /// in the wrong place ("מהאת ה" -> "מה אתה"), which we could not see before.
    func refineAfterSwap(upTo end: Int, includeLast: Bool) -> Bool {
        guard fixSpelling, var s = lastSwap, !s.refined, keys.count >= s.end, end > s.end else { return false }
        let ws = words(upTo: end, includeLast: includeLast)
        guard let ni = ws.firstIndex(where: { $0.r.lowerBound >= s.end }) else { return false }
        s.refined = true; lastSwap = s
        let from = ni > 0 ? ws[ni - 1].r.lowerBound : ws[ni].r.lowerBound
        let heb = !s.oldHeb
        guard from >= s.start, keys[from..<ws[ni].r.upperBound].allSatisfy({ $0.heb == heb }) else { return false }
        let segEnd = ws[ni].r.upperBound
        let seg = text(from..<segEnd)
        let fixed = fixText(seg, heb: heb)
        guard fixed != seg else { return false }
        let L = layout(heb)
        let fk = fixed.compactMap { c -> Key? in guard var k = L.key(for: c) else { return nil }; k.heb = heb; return k }
        guard fk.count == fixed.count else { return false }
        let tail = Array(keys[segEnd...])
        let afterOrig = keys[s.end...].map { k -> Key in var k = k; k.heb = s.oldHeb; return k }
        swapping = true
        output(keys.count - from, fixed + tail.map { ch($0) }.joined(), nil)
        keys.replaceSubrange(from..., with: fk + tail)
        lastSwap = Swap(start: s.start, end: keys.count, oldKeys: s.oldKeys + afterOrig, oldHeb: s.oldHeb, refined: true)
        lockedBefore = keys.count
        endSwapping(fixed.count * 2)
        return true
    }

    // MARK: actions

    func convert(from start: Int, target: Bool, fixUpTo: Int) {
        let region = start..<keys.count
        let oldKeys = Array(keys[region])
        let plain = text(region, as: target)
        var newText = plain
        if fixSpelling {
            let cut = plain.index(plain.startIndex, offsetBy: min(plain.count, max(0, fixUpTo - start)))
            newText = fixText(String(plain[..<cut]), heb: target) + String(plain[cut...])
        }
        let L = layout(target)
        var newKeys: [Key] = []
        for c in newText {
            guard var k = L.key(for: c) else { newKeys = []; break }
            k.heb = target; newKeys.append(k)
        }
        if newKeys.count != newText.count {          // could not map a fixed char back: skip the fixes
            newText = plain
            newKeys = oldKeys.map { var k = $0; k.heb = target; return k }
        }
        log("convert to \(target ? "Hebrew" : "English"): \"\(newText)\"")
        swapping = true
        output(oldKeys.count, newText, target)
        keys.replaceSubrange(region, with: newKeys)
        curHeb = target
        ignoreLayoutUntil = Date().addingTimeInterval(0.8)
        lastSwap = Swap(start: start, end: keys.count, oldKeys: oldKeys, oldHeb: oldKeys.first?.heb ?? !target)
        lockedBefore = keys.count
        endSwapping(oldKeys.count + newKeys.count)
    }

    @discardableResult
    func undo() -> Bool {
        guard let s = lastSwap, keys.count >= s.end else { return false }
        log("undo")
        if let w = s.typoOf { ignoreWords.insert(w); onIgnore?(ignoreWords) }
        let after = keys[s.end...].map { k -> Key in var k = k; k.heb = s.oldHeb; return k }
        let restored = s.oldKeys + after
        let del = keys.count - s.start
        swapping = true
        keys.replaceSubrange(s.start..., with: restored)
        output(del, text(s.start..<keys.count), s.oldHeb)
        curHeb = s.oldHeb
        ignoreLayoutUntil = Date().addingTimeInterval(0.8)
        lockedBefore = keys.count
        lastSwap = nil
        endSwapping(del + restored.count)
        return true
    }

    /// Double-tap Shift: convert the last wrong words (or the last word), or undo the last fix.
    func manual() {
        guard enabled, ready, !swapping else { return }
        if let s = lastSwap, keys.count == s.end { undo(); return }
        // Nothing typed since the last click / arrow keys: you probably selected text. Convert that.
        if keys.isEmpty, !sync { convertSelection(); return }
        let ws = words(upTo: keys.count, includeLast: true)
        guard let last = ws.last else { NSSound.beep(); return }
        let heb = last.heb
        let s = scanBack(ws, heb: heb)?.1 ?? ws.count - 1     // nothing looks wrong: just the last word
        convert(from: ws[s].r.lowerBound, target: !heb, fixUpTo: keys.count)
    }

    /// Convert text between layouts: "akuo kfuko" <-> "שלום לכולם". Returns text and target language.
    func convertString(_ s: String) -> (String, Bool) {
        let hebCount = s.unicodeScalars.filter { (0x05D0...0x05EA).contains($0.value) }.count
        let latCount = s.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        let fromHeb = hebCount > latCount
        let from = layout(fromHeb), to = layout(!fromHeb)
        var out = ""
        for c in s {
            if c == " " || c == "\n" || c == "\t" { out.append(c); continue }
            if let k = from.key(for: c) { out += to.char(k) } else { out.append(c) }
        }
        if fixSpelling {
            out = out.split(separator: "\n", omittingEmptySubsequences: false).map { fixText(String($0), heb: !fromHeb) }.joined(separator: "\n")
        }
        return (out, !fromHeb)
    }

    private func postCmd(_ code: CGKeyCode) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: kMagic)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Copy the selection, convert it, paste it back, then put your clipboard back.
    func convertSelection() {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let n = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { n.setData(d, forType: t) } }
            return n
        }
        func restore() { pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) } }
        let before = pb.changeCount
        postCmd(8)                                                    // Cmd+C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self else { return }
            guard pb.changeCount != before else { NSSound.beep(); return }   // nothing selected
            // Some editors (VS Code) copy the whole line when nothing is selected: don't touch that.
            let fromEmpty = pb.types?.contains { t in
                t.rawValue.contains("vscode") && (pb.string(forType: t)?.contains("\"isFromEmptySelection\":true") ?? false)
            } ?? false
            guard !fromEmpty, let s = pb.string(forType: .string), !s.isEmpty, s.count <= 5000 else { restore(); NSSound.beep(); return }
            let (out, target) = self.convertString(s)
            self.log("convert selection to \(target ? "Hebrew" : "English"): \"\(out)\"")
            pb.clearContents()
            pb.setString(out, forType: .string)
            self.postCmd(9)                                           // Cmd+V (Cmd+Z in the app undoes it)
            self.select(self.layout(target)); self.curHeb = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restore() }
        }
    }

    private func endSwapping(_ events: Int) {
        if sync { swapping = false; return }
        let t = 0.08 + Double(events) * 0.002
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.swapping = false }
    }

    private func trim() {
        var cut = 0
        for i in 0..<keys.count where keys[i].isSpace && keys.count - (i + 1) <= 300 { cut = i + 1; break }
        if cut == 0 { reset(); return }
        keys.removeFirst(cut)
        lockedBefore = max(0, lockedBefore - cut)
        lastSwap = nil
        bufferFresh = false
    }

    // MARK: input

    /// Returns true if the key should reach the app.
    func onKeyDown(code: UInt16, flags f: CGEventFlags) -> Bool {
        shiftDown = nil; lastTap = nil
        guard enabled, ready else { return true }

        if f.contains(.maskCommand) {
            if code == 6, !swapping, f.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty,
               lastSwap != nil, undo() { return false }          // our Cmd+Z
            if !swapping { reset() }
            return true
        }
        if f.contains(.maskControl) || f.contains(.maskAlternate) { reset(); return true }

        if code == 51 {                                          // Backspace
            if keys.isEmpty { return true }
            keys.removeLast()
            if let s = lastSwap, keys.count < s.end { lastSwap = nil }
            lockedBefore = min(lockedBefore, keys.count)
            if swapping { output(1, "", nil); return false }
            return true
        }
        if resetCodes.contains(code) { reset(); return true }
        if let b = frontBundle, excluded.contains(b) { return true }

        let heb: Bool
        if swapping || Date() < ignoreLayoutUntil { heb = curHeb }
        else {
            guard let h = queryLayout() else { log("unknown keyboard layout: reset"); reset(); return true }
            heb = h; curHeb = h
        }
        let key = Key(code: code, shift: f.contains(.maskShift), caps: f.contains(.maskAlphaShift), heb: heb)
        let c = ch(key)
        guard c.unicodeScalars.count == 1, let u = c.unicodeScalars.first,
              u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value) else {
            reset(); return true                                 // F-keys etc.
        }
        keys.append(key)
        if swapping { output(0, c, nil); return false }          // typed while we were retyping
        if keys.count > 400 { trim() }
        if keys.count >= 2, code == 49 || c == "?" || c == "!" {
            let end = keys.count, incl = code != 49
            schedule { [weak self] in self?.check(upTo: end, includeLast: incl) }
        }
        return true
    }

    private var shiftDown: Date?
    private var lastTap: Date?
    private var shiftWas = false

    func onFlags(_ f: CGEventFlags) {
        let sh = f.contains(.maskShift)
        defer { shiftWas = sh }
        if !f.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { shiftDown = nil; lastTap = nil; return }
        let now = Date()
        if sh && !shiftWas { shiftDown = now }
        if !sh && shiftWas {
            if let d = shiftDown, now.timeIntervalSince(d) < 0.3 {
                if let t = lastTap, now.timeIntervalSince(t) < 0.45 {
                    lastTap = nil
                    if hotkey { schedule { [weak self] in self?.manual() } }
                } else { lastTap = now }
            }
            shiftDown = nil
        }
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("macOS paused the key watcher (\(type == .tapDisabledByTimeout ? "timeout" : "user input")): turning it back on")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        if e.getIntegerValueField(.eventSourceUserData) == kMagic { return pass }
        switch type {
        case .keyDown:
            return onKeyDown(code: UInt16(e.getIntegerValueField(.keyboardEventKeycode)), flags: e.flags) ? pass : nil
        case .flagsChanged:
            onFlags(e.flags); return pass
        default:                                                 // mouse click
            if !swapping { reset() }
            shiftDown = nil; lastTap = nil
            if type == .leftMouseDown, let f = onClick {
                let p = e.location
                DispatchQueue.main.async { f(p) }
            }
            return pass
        }
    }

    // MARK: posting

    private func select(_ l: Layout) {
        ignoreLayoutUntil = Date().addingTimeInterval(0.8)
        TISSelectInputSource(l.source)
    }

    private func post(_ code: CGKeyCode, _ text: [UniChar]?) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = []                          // ignore physically held Cmd/Shift
            if let t = text { e.keyboardSetUnicodeString(stringLength: t.count, unicodeString: t) }
            e.setIntegerValueField(.eventSourceUserData, value: kMagic)
            e.post(tap: .cghidEventTap)
        }
    }

    private func postBackspaces(_ n: Int) { for _ in 0..<max(0, n) { post(51, nil) } }

    private func postText(_ s: String) {
        for ch in s {
            if ch == " " { post(49, nil) } else { post(0, Array(String(ch).utf16)) }
        }
    }

    func installTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, _ in engine.handle(type, event) },
                                        userInfo: nil) else { return false }
        let rl = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rl, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }
}

let engine = Engine()

// MARK: - Simulator (tests run the real engine against a fake text field)

final class Sim {
    var screen = ""
    var heb: Bool
    init(heb: Bool) {
        self.heb = heb
        engine.reset()
        engine.sync = true
        engine.ignoreLayoutUntil = .distantPast
        engine.queryLayout = { [unowned self] in self.heb }
        engine.output = { [unowned self] del, text, h in
            self.screen = String(self.screen.dropLast(del)) + text
            if let h = h { self.heb = h }
        }
    }
    func run() { while !engine.pending.isEmpty { engine.pending.removeFirst()() } }

    /// Type the keys that produce `s` in the given layout (what your fingers do).
    func type(_ s: String, keysOf hebKeys: Bool) {
        let L = engine.layout(hebKeys)
        for c in s {
            guard let k = L.key(for: c) else { print("  !! no key for \(c)"); continue }
            let f: CGEventFlags = k.shift ? .maskShift : []
            if engine.onKeyDown(code: k.code, flags: f) {
                if k.code == 51 { screen = String(screen.dropLast()) }
                else { screen += engine.layout(heb).char(Key(code: k.code, shift: k.shift, caps: false, heb: heb)) }
            }
            run()
        }
    }
    func cmdZ() { _ = engine.onKeyDown(code: 6, flags: .maskCommand); run() }
    func doubleShift() { engine.manual(); run() }
}

func selfTest() -> Int {
    guard let en = engine.en, let he = engine.he else { print("Missing layouts"); return 1 }
    print("English layout: \(en.id)\nHebrew layout:  \(he.id)\n")
    engine.loadSpellers(dir: testResourcesDir())
    print("Spellers loaded: en=\(engine.spellers[false] != nil) he=\(engine.spellers[true] != nil)\n")
    var fails = 0
    func t(_ name: String, startHeb: Bool, _ steps: (Sim) -> Void, expect: String) {
        let sim = Sim(heb: startHeb)
        let t0 = Date()
        steps(sim)
        let ms = Date().timeIntervalSince(t0) * 1000
        let ok = sim.screen == expect
        if !ok { fails += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\n      got:    \(sim.screen)\n      wanted: \(expect)   (\(String(format: "%.0f", ms)) ms)")
    }
    // keysOf: true = fingers typed Hebrew-layout keys, false = English-layout keys
    t("Hebrew typed on English layout", startHeb: false, { $0.type("nv vnmc tjh? ", keysOf: false) }, expect: "מה המצב אחי? ")
    t("English typed on Hebrew layout", startHeb: true, { $0.type("what do you want from me? ", keysOf: false) }, expect: "what do you want from me? ")
    t("Normal English stays", startHeb: false, { $0.type("hello there my friend, I need to go home now ", keysOf: false) }, expect: "hello there my friend, I need to go home now ")
    t("Normal Hebrew stays", startHeb: true, { $0.type("שלום לכולם מה קורה היום ", keysOf: true) }, expect: "שלום לכולם מה קורה היום ")
    t("English typos fixed, not flipped", startHeb: false, { $0.type("I went to the ofice yestreday and teh boss ", keysOf: false) }, expect: "I went to the office yesterday and the boss ")
    t("Switch mid-sentence EN -> HE", startHeb: false,
      { $0.type("if right now after this very word i want to switch then ", keysOf: false); $0.type("שאני יכול פשוט לכתוב בעברית ", keysOf: true) },
      expect: "if right now after this very word i want to switch then שאני יכול פשוט לכתוב בעברית ")
    t("Switch mid-sentence HE -> EN", startHeb: true,
      { $0.type("אני רוצה ", keysOf: true); $0.type("send the file ", keysOf: false) },
      expect: "אני רוצה send the file ")
    t("Misplaced space fixed (nvt, v tunr)", startHeb: false, { $0.type("nvt, v tunr ", keysOf: false) }, expect: "מה אתה אומר ")
    t("Missing space fixed", startHeb: false, { $0.type("nvvnmc tjh ", keysOf: false) }, expect: "מה המצב אחי ")
    t("Typo fixed while converting", startHeb: false, { $0.type("אני רוהצ לראות את הדוח ", keysOf: true) }, expect: "אני רוצה לראות את הדוח ")
    t("One word with ?", startHeb: true, { $0.type("shorter?", keysOf: false) }, expect: "shorter?")
    t("Cmd+Z undoes", startHeb: false, { $0.type("nv vnmc tjh? ", keysOf: false); $0.cmdZ() }, expect: "nv vnmc tjh? ")
    t("Cmd+Z then keep typing stays", startHeb: false, { $0.type("nv vnmc tjh? ", keysOf: false); $0.cmdZ(); $0.type("ok ", keysOf: false) }, expect: "nv vnmc tjh? ok ")
    t("Double Shift converts last word", startHeb: false, { $0.type("I said akuo", keysOf: false); $0.doubleShift() }, expect: "I said שלום")
    t("Double Shift twice = back", startHeb: false, { $0.type("I said akuo", keysOf: false); $0.doubleShift(); $0.doubleShift() }, expect: "I said akuo")
    t("Typos fixed, same language", startHeb: false, { $0.type("I made few typos in speling and mispelled words automatecally ", keysOf: false) },
      expect: "I made few typos in spelling and misspelled words automatically ")
    t("Contraction fixed", startHeb: false, { $0.type("it doesnt matter ", keysOf: false) }, expect: "it doesn't matter ")
    t("Names and brands left alone", startHeb: false, { $0.type("talk to Zorvex about Slack and zorvex ", keysOf: false) }, expect: "talk to Zorvex about Slack and zorvex ")
    t("Cmd+Z keeps your word, and it is not fixed again", startHeb: false,
      { $0.type("speling ", keysOf: false); $0.cmdZ(); $0.type("speling ", keysOf: false) }, expect: "speling speling ")
    t("Hebrew typo fixed", startHeb: true, { $0.type("אני רוצה לראות את הדוח של אתמול בבוקר עכשוי ", keysOf: true) }, expect: "אני רוצה לראות את הדוח של אתמול בבוקר עכשיו ")
    t("Wrong keyboard still wins over typo fix", startHeb: false, { $0.type("akuo kfuko ", keysOf: false) }, expect: "שלום לכולם ")
    t("Hebrew neighbour-key typo with final letter", startHeb: true, { $0.type("וואלה עובד יםה סהכ ", keysOf: true) }, expect: "וואלה עובד יפה סהכ ")
    t("English on Hebrew keyboard with dont + lone i", startHeb: true, { $0.type("i dont want to change it ", keysOf: false) }, expect: "I don't want to change it ")
    t("Common word before switch comes along (tbh = אני)", startHeb: false, { $0.type("this is great but tbh hfuk kf,uc cgcrh, ", keysOf: false) }, expect: "this is great but אני יכול לכתוב בעברית ")
    t("But 'to' stays English", startHeb: false, { $0.type("I want to akuo kfuko ", keysOf: false) }, expect: "I want to שלום לכולם ")
    t("Lone i becomes I", startHeb: true, { $0.type("i want to make you ", keysOf: false) }, expect: "I want to make you ")
    do {
        let (a, ha) = engine.convertString("akuo kfuko")
        let (b, hb) = engine.convertString("׳ישא גם טםו ׳שמא")
        let ok = a == "שלום לכולם" && ha && b == "what do you want" && !hb
        if !ok { fails += 1 }
        print("\(ok ? "PASS" : "FAIL")  Selected text converts\n      got:    \(a) | \(b)")
    }
    engine.ignoreWords.removeAll()
    return fails
}

// Sentence tests on word lists: false swaps (right layout, with typos) and catches (wrong layout).
func listTest(_ enPath: String, _ hePath: String) {
    func load(_ p: String) -> [String] {
        ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.count >= 2 }
    }
    let enW = load(enPath), heW = load(hePath)
    engine.loadSpellers(dir: testResourcesDir())
    var seed: UInt64 = 42
    func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    func typo(_ w: String) -> String {
        var c = Array(w); guard c.count >= 3 else { return w }
        let k = rnd(c.count - 1); c.swapAt(k, k + 1); return String(c)
    }
    for (name, words, heb) in [("English", enW, false), ("Hebrew", heW, true)] {
        var fp = 0, caught = 0, n = 300
        var examples: [String] = []
        var tRight = 0, tWrong = 0, tLeft = 0
        for _ in 0..<n {
            let orig = (0..<6).map { _ in words[rnd(words.count)] }
            let typed = orig.map { rnd(4) == 0 ? typo($0) : $0 }
            let s = typed.joined(separator: " ") + " "
            let sim = Sim(heb: heb); sim.type(s, keysOf: heb)
            let otherScript = sim.screen.unicodeScalars.contains { heb ? ($0.isASCII && CharacterSet.letters.contains($0)) : (0x05D0...0x05EA).contains($0.value) }
            if otherScript { fp += 1; if examples.count < 6 { examples.append("\(s)-> \(sim.screen)") } }
            else {
                let got = sim.screen.split(separator: " ").map(String.init)
                if got.count == orig.count {
                    for k in 0..<orig.count where typed[k] != orig[k] {
                        if got[k] == orig[k] { tRight += 1 } else if got[k] == typed[k] { tLeft += 1 } else { tWrong += 1 }
                    }
                    for k in 0..<orig.count where typed[k] == orig[k] && got[k] != orig[k] { tWrong += 1; if examples.count < 6 { examples.append("changed good word: \(orig[k]) -> \(got[k])") } }
                }
            }
            let clean = (0..<3).map { _ in words[rnd(words.count)] }.joined(separator: " ") + " "
            let sim2 = Sim(heb: !heb); sim2.type(clean, keysOf: heb)
            if sim2.screen == clean { caught += 1 }
        }
        print("\(name): language flipped by mistake \(fp)/\(n) sentences; fully fixed \(caught)/\(n) wrong-layout sentences")
        print("    typos: fixed right \(tRight), fixed WRONG \(tWrong), left alone \(tLeft)")
        for e in examples { print("    \(e)") }
    }
}


// MARK: - Language badge next to where you click into a text field

final class Badge {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 34, height: 20),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: panel.contentView!.bounds)
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 2, width: 34, height: 16)
        v.addSubview(label)
        panel.contentView = v
    }

    /// p = click point in screen coordinates (Cocoa: origin bottom-left).
    func show(heb: Bool, at p: NSPoint) {
        label.stringValue = heb ? "עב" : "EN"
        panel.contentView?.layer?.backgroundColor = (heb ? NSColor.systemOrange : NSColor.systemBlue).withAlphaComponent(0.92).cgColor
        panel.setFrameOrigin(NSPoint(x: p.x - 17, y: p.y - 34))        // just under the line you clicked
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

/// Chrome, Electron apps (Slack, Claude, VS Code...): asking them for accessibility info can
/// switch on their slow accessibility mode, so for them we trust the text cursor shape only.
func isChromium(_ app: NSRunningApplication) -> Bool {
    guard let url = app.bundleURL else { return false }
    let fw = url.appendingPathComponent("Contents/Frameworks")
    let items = (try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []
    return items.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chrome Framework") || $0.contains("Chromium") || $0.hasPrefix("Microsoft Edge Framework") || $0.hasPrefix("Brave Browser Framework") }
}

func focusedIsEditable(_ pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success, let el = f else { return false }
    let e = el as! AXUIElement
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
    let r = role as? String ?? ""
    if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return true }
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
    return settable.boolValue && r != "AXCheckBox" && r != "AXSlider" && r != "AXPopUpButton"
}

// MARK: - App / menu

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let defaults = UserDefaults.standard
    var permTimer: Timer?
    var secureTimer: Timer?
    var secureApp: String?          // app that turned on Secure Input (password field), if any
    var showBadge = true
    lazy var badge = Badge()
    var chromiumCache: [String: Bool] = [:]

    /// You clicked: if it was into a text field, show the current language next to it.
    func clicked(at cg: CGPoint) {
        guard showBadge, engine.enabled, engine.ready else { return }
        guard let c = NSCursor.currentSystem, c.hotSpot == NSCursor.iBeam.hotSpot,
              c.image.size == NSCursor.iBeam.image.size else { return }          // not the text cursor
        let h = NSScreen.screens.first?.frame.height ?? 0
        let p = NSPoint(x: cg.x, y: h - cg.y)
        // Wait a moment: the click may also switch apps and move the focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, let app = NSWorkspace.shared.frontmostApplication else { return }
            let id = app.bundleIdentifier ?? ""
            if id == Bundle.main.bundleIdentifier || engine.excluded.contains(id) { return }
            let chromium = self.chromiumCache[id] ?? { let v = isChromium(app); self.chromiumCache[id] = v; return v }()
            if !chromium, !focusedIsEditable(app.processIdentifier) { return }   // text you can only read
            guard let heb = engine.currentHebForBadge else { return }
            self.badge.show(heb: heb, at: p)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        engine.loadLayouts()
        engine.enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        engine.fixSpelling = defaults.object(forKey: "fixSpelling") as? Bool ?? true
        engine.hotkey = defaults.object(forKey: "hotkey") as? Bool ?? true
        engine.excluded = Set(defaults.stringArray(forKey: "excluded") ?? [])
        engine.autoCorrect = defaults.object(forKey: "autoCorrect") as? Bool ?? true
        engine.ignoreWords = Set(defaults.stringArray(forKey: "ignoreWords") ?? [])
        engine.onIgnore = { [weak self] set in self?.defaults.set(Array(set), forKey: "ignoreWords") }
        if let dir = Bundle.main.resourcePath { engine.loadSpellers(dir: dir) }
        showBadge = defaults.object(forKey: "showBadge") as? Bool ?? true
        engine.onClick = { [weak self] p in self?.clicked(at: p) }
        engine.frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        engine.warmUp()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        refreshIcon()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            engine.frontBundle = app?.bundleIdentifier
            engine.reset()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { _ in
            engine.loadLayouts(); engine.reset(); self.refreshIcon()
        }
        startTap()
        // While another app has Secure Input on, macOS hides all keystrokes from us. Show it.
        secureTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkSecureInput() }
        checkSecureInput()
    }

    func checkSecureInput() {
        var name: String?
        if IsSecureEventInputEnabled() {
            name = "another app"
            if let d = CGSessionCopyCurrentDictionary() as? [String: Any],
               let pid = (d["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0,
               let app = NSRunningApplication(processIdentifier: pid) {
                name = app.localizedName ?? name
            }
        }
        if name != secureApp {
            engine.log("secure input: \(name ?? "off")")
            secureApp = name
            if name != nil { engine.reset() }
            refreshIcon()
        }
    }

    func startTap() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), engine.installTap() { refreshIcon(); return }
        refreshIcon()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if AXIsProcessTrusted(), engine.installTap() { t.invalidate(); self?.refreshIcon() }
        }
    }

    func refreshIcon() {
        var title = "אA"
        if engine.tap == nil || !engine.ready { title += " ⚠︎" }
        else if secureApp != nil { title += " 🔒" }
        item.button?.title = title
        item.button?.alphaValue = engine.enabled ? 1.0 : 0.4
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if engine.tap == nil {
            menu.addItem(withTitle: "Needs Accessibility permission…", action: #selector(openAX), keyEquivalent: "").target = self
        }
        if let a = secureApp, engine.tap != nil {
            menu.addItem(NSMenuItem(title: "🔒 Paused: \(a) is protecting a password field", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "     Click away from it, close that tab, or quit \(a)", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }
        if !engine.ready {
            menu.addItem(NSMenuItem(title: "Add both Hebrew and ABC/US keyboards in System Settings", action: nil, keyEquivalent: ""))
        }
        func toggle(_ title: String, _ on: Bool, _ sel: Selector) {
            let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: ""); i.target = self; i.state = on ? .on : .off
        }
        toggle("Auto-fix wrong language", engine.enabled, #selector(toggleEnabled))
        toggle("Fix typos when converting", engine.fixSpelling, #selector(toggleFix))
        toggle("Auto-correct typos", engine.autoCorrect, #selector(toggleAutoCorrect))
        toggle("Show language when clicking a text field", showBadge, #selector(toggleBadge))
        toggle("Double-tap Shift = convert by hand", engine.hotkey, #selector(toggleHotkey))
        if let app = NSWorkspace.shared.frontmostApplication, let b = app.bundleIdentifier, b != Bundle.main.bundleIdentifier {
            let ex = menu.addItem(withTitle: "Disable in \(app.localizedName ?? b)", action: #selector(toggleExcluded(_:)), keyEquivalent: "")
            ex.target = self; ex.representedObject = b; ex.state = engine.excluded.contains(b) ? .on : .off
        }
        toggle("Start at login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        toggle(Date() < engine.logUntil ? "Recording debug log… (click to stop)" : "Record debug log for 10 min", Date() < engine.logUntil, #selector(toggleLog))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cmd+Z right after a fix = undo (and never fix that word again)", action: nil, keyEquivalent: ""))
        menu.addItem(withTitle: "Quit LangSwap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func toggleEnabled() {
        engine.enabled.toggle(); engine.reset()
        defaults.set(engine.enabled, forKey: "enabled"); refreshIcon()
    }
    @objc func toggleFix() { engine.fixSpelling.toggle(); defaults.set(engine.fixSpelling, forKey: "fixSpelling") }
    @objc func toggleLog() {
        if Date() < engine.logUntil {
            engine.logUntil = .distantPast
            NSWorkspace.shared.activateFileViewerSelecting([Engine.logURL])
        } else {
            try? "".write(to: Engine.logURL, atomically: true, encoding: .utf8)
            engine.logUntil = Date().addingTimeInterval(600)
            engine.log("log started. LangSwap \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"), layouts en=\(engine.en?.id ?? "-") he=\(engine.he?.id ?? "-"), secure input: \(secureApp ?? "off")")
        }
    }
    @objc func toggleBadge() { showBadge.toggle(); defaults.set(showBadge, forKey: "showBadge") }
    @objc func toggleAutoCorrect() { engine.autoCorrect.toggle(); defaults.set(engine.autoCorrect, forKey: "autoCorrect") }
    @objc func toggleHotkey() { engine.hotkey.toggle(); defaults.set(engine.hotkey, forKey: "hotkey") }
    @objc func toggleExcluded(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? String else { return }
        if engine.excluded.contains(b) { engine.excluded.remove(b) } else { engine.excluded.insert(b) }
        defaults.set(Array(engine.excluded), forKey: "excluded"); engine.reset()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

func typoTest(_ enPath: String, _ hePath: String) {
    for (path, heb) in [(enPath, false), (hePath, true)] {
        guard let sp = Speller(path: path, heb: heb) else { print("cannot load \(path)"); continue }
        engine.spellers[heb] = sp
        let words = sp.freq.sorted { $0.value > $1.value }.prefix(5000).map { $0.key }.filter { $0.count >= 4 }
        let alpha = Array(Set(words.prefix(2000).joined()))
        var seed: UInt64 = 7
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        func near(_ c: Character) -> Character { let l = alpha.filter { $0 != c && sp.adj($0, c) }; return l.isEmpty ? alpha[rnd(alpha.count)] : l[rnd(l.count)] }
        var cases: [(String, String)] = []
        while cases.count < 400 {
            let w = words[rnd(words.count)]; var c = Array(w); let i = rnd(c.count)
            switch rnd(5) {
            case 0: c.remove(at: i)
            case 1: if i < c.count - 1 { c.swapAt(i, i + 1) }
            case 2: c.insert(near(c[i]), at: i)
            case 3: c[i] = near(c[i])
            default: c[i] = alpha[rnd(alpha.count)]
            }
            let t = String(c)
            if t != w, !engine.isWord(t, heb: heb) { cases.append((w, t)) }
        }
        for m in [1.3, 1.5, 1.75, 2.0] {
            sp.margin = m
            var right = 0, wrong = 0, none = 0, bad: [String] = []
            let t0 = Date()
            for (w, t) in cases {
                if let b = engine.correct(t, heb: heb) { if b == w { right += 1 } else { wrong += 1; if bad.count < 6 { bad.append("\(t)->\(b) (\(w))") } } } else { none += 1 }
            }
            let ms = Date().timeIntervalSince(t0) * 1000 / Double(cases.count)
            print("\(heb ? "Hebrew " : "English") margin \(m): right \(right), WRONG \(wrong), left alone \(none)   \(String(format: "%.1f", ms)) ms/word  \(bad)")
        }
    }
    engine.spellers[false]?.margin = 1.3; engine.spellers[true]?.margin = 1.35
    for w in ["mispelled", "speling", "automatecally", "seperate", "tommorow", "untill", "goverment", "doesnt", "recieve", "definately", "zorvex", "quixly"] {
        print(w, "->", engine.correct(w, heb: false) ?? (Speller.contractions[w] ?? "(left alone)"))
    }
}

/// Word lists for tests: ./resources when run from the repo folder.
func testResourcesDir() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    let r = (cwd as NSString).appendingPathComponent("resources")
    return FileManager.default.fileExists(atPath: r) ? r : cwd
}

let args = CommandLine.arguments
if args.contains("--badgedemo") {
    let a = NSApplication.shared; a.setActivationPolicy(.accessory)
    let b = Badge()
    let m = NSEvent.mouseLocation
    b.show(heb: true, at: NSPoint(x: m.x, y: m.y))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        let t = Process(); t.launchPath = "/usr/sbin/screencapture"
        t.arguments = ["-x", "-R\(Int(m.x) - 80),\(Int((NSScreen.screens.first?.frame.height ?? 0) - m.y) - 40),160,90", "/tmp/badge.png"]
        try? t.run(); t.waitUntilExit()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
    a.run()
}
// --sim "<text>" en|he(start layout)  : type the text's keys and show what you would get
if let i = args.firstIndex(of: "--sim"), args.count > i + 2 {
    engine.loadLayouts()
    engine.loadSpellers(dir: testResourcesDir())
    let txt = args[i + 1], startHeb = args[i + 2] == "he"
    let keysHeb = txt.unicodeScalars.contains { (0x05D0...0x05EA).contains($0.value) }
    let sim = Sim(heb: startHeb)
    sim.type(txt, keysOf: keysHeb)
    print("typed:  \(txt)\nresult: \(sim.screen)")
    exit(0)
}
if let i = args.firstIndex(of: "--typotest"), args.count > i + 2 {
    engine.loadLayouts()
    typoTest(args[i + 1], args[i + 2])
    exit(0)
}
if args.contains("--selftest") {
    engine.loadLayouts()
    let f = selfTest()
    print(f == 0 ? "\nALL PASS" : "\n\(f) FAILED")
    exit(0)
}
if let i = args.firstIndex(of: "--lists"), args.count > i + 2 {
    engine.loadLayouts()
    listTest(args[i + 1], args[i + 2])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
