import Foundation

/// 多路免 Key 在线翻译引擎（并发竞速 + 多级自动故障转移，零配置永不罢工）
enum MultiSourceTranslator {

    struct TargetLanguageOption {
        let code: String
        let title: String
    }

    static let targetLanguages: [TargetLanguageOption] = [
        TargetLanguageOption(code: "zh-CN", title: "简体中文"),
        TargetLanguageOption(code: "zh-TW", title: "繁體中文"),
        TargetLanguageOption(code: "en", title: "英语 (English)"),
        TargetLanguageOption(code: "ja", title: "日语 (日本語)")
    ]

    static var currentTargetLanguage: String {
        get { UserDefaults.standard.string(forKey: "target_language_code") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "target_language_code") }
    }

    /// 批量翻译所有文本块，保持与输入数组 1:1 严格对齐
    static func translateBlocks(_ texts: [String], targetLang: String = currentTargetLanguage) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        // 区分无需翻译的纯数字/符号行，减少噪声并保证原样保留
        var indicesToTranslate: [Int] = []
        var cleanInputs: [String] = []
        var results = texts

        for (i, raw) in texts.enumerated() {
            let oneLine = raw
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldSkipTranslation(oneLine, targetLang: targetLang) {
                results[i] = oneLine
            } else {
                indicesToTranslate.append(i)
                cleanInputs.append(oneLine)
            }
        }

        guard !cleanInputs.isEmpty else { return results }

        // 优先走腾讯交互翻译原生数组批量接口（国内零代理直连 0.3~0.4s 秒回，且数组 1:1 严格对齐绝不错行）与 Google 并发竞速！
        if let fastBatch = try? await raceBatchTranslate(cleanInputs, targetLang: targetLang),
           fastBatch.count == cleanInputs.count {
            for (offset, originalIdx) in indicesToTranslate.enumerated() {
                let t = fastBatch[offset].trimmingCharacters(in: .whitespacesAndNewlines)
                results[originalIdx] = t.isEmpty ? cleanInputs[offset] : t
            }
            return results
        }

        // 兜底：并发逐条翻译精确对齐
        let individualTranslated = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (offset, text) in cleanInputs.enumerated() {
                group.addTask {
                    let translated = try await raceTranslateText(text, targetLang: targetLang)
                    return (offset, translated.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            var map: [Int: String] = [:]
            for try await (offset, val) in group {
                map[offset] = val
            }
            return map
        }

        for (offset, originalIdx) in indicesToTranslate.enumerated() {
            if let val = individualTranslated[offset], !val.isEmpty {
                results[originalIdx] = val
            }
        }
        return results
    }

    /// 判断纯数字/标点或已经是纯中文（当目标语言为中文时且不含英日韩字母）是否无需翻译
    private static func shouldSkipTranslation(_ text: String, targetLang: String) -> Bool {
        if text.isEmpty { return true }
        let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasLetters { return true }

        // 如果目标是中文，且整行全是汉字与常见标点（没有拉丁字母、假名、谚文、西里尔字母），直接保留原中文
        if targetLang.hasPrefix("zh") {
            var hasForeignLetter = false
            for s in text.unicodeScalars {
                let v = s.value
                if CharacterSet.letters.contains(s) {
                    let isHan = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                    if !isHan {
                        hasForeignLetter = true
                        break
                    }
                }
            }
            if !hasForeignLetter { return true }
        }
        return false
    }

    /// 批量多路竞速：腾讯国内强制直连数组接口（0.35s）与 Google 多行接口同时竞速，谁快用谁！
    static func raceBatchTranslate(_ cleanInputs: [String], targetLang: String) async throws -> [String] {
        return try await withThrowingTaskGroup(of: [String].self, returning: [String].self, body: { group in
            // 线路 A：腾讯 TranSmart 官方免 Key 数组接口（强制直连国内 CDN，绕过慢速代理，0.35s 响应）
            group.addTask {
                try await translateBatchViaTencent(cleanInputs, targetLang: targetLang)
            }
            // 线路 B：Google AT 多行接口
            group.addTask {
                let joined = cleanInputs.joined(separator: "\n")
                let res = try await translateViaGoogleSingle(
                    host: "https://translate.google.com",
                    client: "at",
                    text: joined,
                    targetLang: targetLang
                )
                let lines = res.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                guard lines.count == cleanInputs.count else { throw URLError(.cannotParseResponse) }
                return lines
            }
            // 线路 C：Google GTX 多行接口
            group.addTask {
                let joined = cleanInputs.joined(separator: "\n")
                let res = try await translateViaGoogleSingle(
                    host: "https://translate.googleapis.com",
                    client: "gtx",
                    text: joined,
                    targetLang: targetLang
                )
                let lines = res.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                guard lines.count == cleanInputs.count else { throw URLError(.cannotParseResponse) }
                return lines
            }

            var lastErr: Error?
            while let next = await group.nextResult() {
                switch next {
                case .success(let list) where list.count == cleanInputs.count:
                    group.cancelAll()
                    return list
                case .failure(let err):
                    lastErr = err
                default:
                    break
                }
            }
            throw lastErr ?? URLError(.badServerResponse)
        })
    }

    /// 单条多路引擎竞速 + 自动降级容灾
    static func raceTranslateText(_ text: String, targetLang: String) async throws -> String {
        let raced = try? await withThrowingTaskGroup(of: String.self, returning: String.self, body: { group in
            group.addTask {
                let arr = try await translateBatchViaTencent([text], targetLang: targetLang)
                guard let first = arr.first, !first.isEmpty else { throw URLError(.zeroByteResource) }
                return first
            }
            group.addTask {
                try await translateViaGoogleSingle(
                    host: "https://translate.google.com",
                    client: "at",
                    text: text,
                    targetLang: targetLang
                )
            }
            group.addTask {
                try await translateViaGoogleSingle(
                    host: "https://translate.googleapis.com",
                    client: "gtx",
                    text: text,
                    targetLang: targetLang
                )
            }

            var firstError: Error?
            while let next = await group.nextResult() {
                switch next {
                case .success(let value) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    group.cancelAll()
                    return value
                case .failure(let err):
                    firstError = err
                default:
                    break
                }
            }
            throw firstError ?? URLError(.badServerResponse)
        })
        if let fastResult = raced {
            return fastResult
        }

        // 第二梯队兜底：Google Clients5 接口
        if let backup1 = try? await translateViaGoogleClients5(text: text, targetLang: targetLang),
           !backup1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return backup1
        }

        // 第三梯队终极兜底：MyMemory 免费翻译 API
        return try await translateViaMyMemory(text: text, targetLang: targetLang)
    }

    private static func makeSession(timeout: TimeInterval = 4.0, directNoProxy: Bool = false) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1.5
        if directNoProxy {
            cfg.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: cfg)
    }

    /// 线路 0（国内最快主力）: 腾讯交互翻译 TranSmart 原生数组免 Key 接口
    private static func translateBatchViaTencent(_ texts: [String], targetLang: String) async throws -> [String] {
        guard let url = URL(string: "https://transmart.qq.com/api/imt") else {
            throw URLError(.badURL)
        }
        let mappedTarget: String
        if targetLang.hasPrefix("zh") {
            mappedTarget = "zh"
        } else if targetLang.hasPrefix("ja") {
            mappedTarget = "ja"
        } else if targetLang.hasPrefix("en") {
            mappedTarget = "en"
        } else {
            mappedTarget = targetLang
        }

        let payload: [String: Any] = [
            "header": [
                "fn": "auto_translation",
                "client_key": "browser-chrome-120.0.0-Mac OS-df4bd4c5-a65d-44b2-a40f-42f34f3535f2-\(Int(Date().timeIntervalSince1970 * 1000))"
            ],
            "type": "plain",
            "model_category": "normal",
            "source": [
                "text_list": texts
            ],
            "target": [
                "lang": mappedTarget
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // 优先国内直连（0.35s），若特殊网络需走代理则自动尝试默认代理会话
        let data: Data
        let resp: URLResponse
        if let directPair = try? await makeSession(timeout: 3.2, directNoProxy: true).data(for: req) {
            data = directPair.0
            resp = directPair.1
        } else {
            (data, resp) = try await makeSession(timeout: 3.5, directNoProxy: false).data(for: req)
        }

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["auto_translation"] as? [String],
              list.count == texts.count else {
            throw URLError(.cannotParseResponse)
        }
        return list
    }

    /// 线路 1 & 2: Google translate_a/single (支持多行严格对齐)
    private static func translateViaGoogleSingle(host: String, client: String, text: String, targetLang: String) async throws -> String {
        var comps = URLComponents(string: "\(host)/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: client),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            throw URLError(.cannotParseResponse)
        }

        var output = ""
        for item in sentences {
            if let arr = item as? [Any], let seg = arr.first as? String {
                output += seg
            }
        }
        if output.isEmpty { throw URLError(.zeroByteResource) }
        return output
    }

    /// 线路 3: Google clients5 dict-chrome-ex
    private static func translateViaGoogleClients5(text: String, targetLang: String) async throws -> String {
        var comps = URLComponents(string: "https://clients5.google.com/translate_a/t")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "dict-chrome-ex"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let outer = json as? [[Any]], let first = outer.first, let translated = first.first as? String {
            return translated
        }
        if let arr = json as? [String], let first = arr.first {
            return first
        }
        throw URLError(.cannotParseResponse)
    }

    /// 线路 4: MyMemory 免费兜底接口
    private static func translateViaMyMemory(text: String, targetLang: String) async throws -> String {
        // MyMemory 逐行处理最稳妥
        let lines = text.components(separatedBy: "\n")
        var outLines: [String] = []
        let session = makeSession(timeout: 6.0)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                outLines.append("")
                continue
            }
            var comps = URLComponents(string: "https://api.mymemory.translated.net/get")!
            comps.queryItems = [
                URLQueryItem(name: "q", value: String(trimmed.prefix(480))),
                URLQueryItem(name: "langpair", value: "autodetect|\(targetLang)")
            ]
            guard let url = comps.url else { throw URLError(.badURL) }
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let respData = dict["responseData"] as? [String: Any],
                  let translated = respData["translatedText"] as? String else {
                throw URLError(.cannotParseResponse)
            }
            outLines.append(translated)
        }
        return outLines.joined(separator: "\n")
    }
}
