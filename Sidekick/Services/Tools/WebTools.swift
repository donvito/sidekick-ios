import Foundation

struct DateTimeTool: AgentTool {
    let name = "get_current_datetime"
    let description = "Returns the current date, time, weekday and timezone of the user."
    let parameters = JSONSchema.object([:])

    func summary(for args: JSONValue) -> String { "Checking the current date and time" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .long
        return "\(f.string(from: .now)) (timezone: \(TimeZone.current.identifier))"
    }
}

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Search the web. Returns titles, URLs and snippets for the top results. Follow up with fetch_url to read a page in depth."
    let parameters = JSONSchema.object([
        "query": JSONSchema.string("The search query"),
    ], required: ["query"])

    func summary(for args: JSONValue) -> String { "Searching the web for “\(args["query"]?.stringValue ?? "")”" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let query = args["query"]?.stringValue, !query.isEmpty else { throw ToolError("query is required") }
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        let results = Self.parseResults(html)
        if results.isEmpty { return "No results found for \(query)." }
        return results.prefix(8).enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n\n")
    }

    struct Result { var title: String; var url: String; var snippet: String }

    static func parseResults(_ html: String) -> [Result] {
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#
        let links = HTMLText.matches(linkPattern, in: html)
        let snippets = HTMLText.matches(snippetPattern, in: html)
        var results: [Result] = []
        for (i, link) in links.enumerated() {
            var url = link[0]
            if let comps = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let real = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = real
            }
            let snippet = i < snippets.count ? HTMLText.strip(snippets[i][0]) : ""
            results.append(Result(title: HTMLText.strip(link[1]), url: url, snippet: snippet))
        }
        return results
    }
}

struct FetchURLTool: AgentTool {
    let name = "fetch_url"
    let description = "Fetch a web page and return its readable text content (scripts and markup removed). Use to read articles, docs or search results in depth."
    let parameters = JSONSchema.object([
        "url": JSONSchema.string("Absolute http(s) URL to fetch"),
    ], required: ["url"])

    func summary(for args: JSONValue) -> String { "Reading \(args["url"]?.stringValue ?? "page")" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard let raw = args["url"]?.stringValue, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw ToolError("A valid http(s) url is required")
        }
        guard SafeHTTP.isPublicHost(url) else {
            throw ToolError("Only public internet URLs can be fetched.")
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await SafeHTTP.download(req, limit: 5_000_000)
        let mime = response.mimeType ?? ""
        if mime.contains("pdf") {
            return AttachmentImporter.extractPDFText(data: data) ?? "Could not extract text from PDF."
        }
        let html = String(decoding: data, as: UTF8.self)
        let text = HTMLText.readableText(html)
        return String(text.prefix(12_000))
    }
}

enum SafeHTTP {
    /// Rejects loopback, link-local and RFC1918 hosts so a prompted tool call cannot probe local services.
    static func isPublicHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 { return false }
            if parts[0] == 169 && parts[1] == 254 { return false }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return false }
            if parts[0] == 192 && parts[1] == 168 { return false }
        }
        if host.contains(":") {
            if host == "::1" || host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd") { return false }
        }
        return true
    }

    /// Streams a response, failing once `limit` bytes are exceeded instead of buffering unbounded data.
    static func download(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            throw ToolError("Response is too large (\(response.expectedContentLength / 1_000_000) MB).")
        }
        var data = Data()
        data.reserveCapacity(min(limit, Int(max(0, response.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw ToolError("Response exceeded the \(limit / 1_000_000) MB limit.") }
        }
        return (data, response)
    }
}

enum HTMLText {
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    static func strip(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readableText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        out = out.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        return out
    }
}
