import Foundation
import Testing
@testable import UsageDock

@Suite("DeepSeek Harness credential reuse")
struct DeepSeekHarnessCredentialReaderTests {
    private static let fixtureKey = "sk-fixture0000000000000000000000000"

    /// 假的用户主目录:`<home>/.dsh/.credentials.yaml`,可选 `.env` 与 patch 文件。
    private func makeHome(
        credentials: String?,
        dotenv: String? = nil,
        homePatch: String? = nil,
        profilePatches: [String: String] = [:]
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "dsh-reader-\(UUID().uuidString)")
        let dsh = home.appending(path: ".dsh")
        try FileManager.default.createDirectory(at: dsh, withIntermediateDirectories: true)
        if let credentials {
            try Data(credentials.utf8).write(to: dsh.appending(path: ".credentials.yaml"))
        }
        if let dotenv {
            try Data(dotenv.utf8).write(to: dsh.appending(path: ".env"))
        }
        if let homePatch {
            try Data(homePatch.utf8).write(to: dsh.appending(path: "cordis.patch.yml"))
        }
        for (name, patch) in profilePatches {
            let profile = dsh.appending(path: "profiles/\(name)")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data(patch.utf8).write(to: profile.appending(path: "cordis.patch.yml"))
        }
        return home
    }

    private func credentials(_ value: String) -> String {
        """
        version: 1

        refs:
          OPENAI_API_KEY: sk-other-fixture
          DEEPSEEK_API_KEY: \(value)

        records:
          llm-pi-ai/openai-codex:
            kind: grant
            payload:
              type: oauth
              access: fixture-access
        """
    }

    @Test("Reads refs.DEEPSEEK_API_KEY from the default ~/.dsh home")
    func readsDefaultHome() throws {
        let home = try makeHome(credentials: credentials(Self.fixtureKey))
        let reader = DeepSeekHarnessCredentialReader(environment: [:], home: home)
        #expect(reader.load() == Self.fixtureKey)
        #expect(reader.isAvailable)
    }

    @Test("A non-blank DSH_HOME wins; a blank one is ignored")
    func honorsDshHome() throws {
        let home = try makeHome(credentials: credentials(Self.fixtureKey))
        let custom = home.appending(path: ".dsh").path
        let elsewhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(DeepSeekHarnessCredentialReader(environment: ["DSH_HOME": custom], home: elsewhere).load()
            == Self.fixtureKey)
        #expect(DeepSeekHarnessCredentialReader(environment: ["DSH_HOME": "  "], home: home).load()
            == Self.fixtureKey)
    }

    @Test("Quoted scalars and trailing comments resolve to the bare key")
    func parsesScalarForms() {
        let key = Self.fixtureKey
        for value in ["'\(key)'", "\"\(key)\"", "\(key) # saved by dsh", "'\(key)' # note"] {
            #expect(DeepSeekHarnessCredentialReader.apiKey(fromCredentialsYAML: credentials(value)) == key)
        }
        let quotedKey = "version: 1\nrefs:\n  \"DEEPSEEK_API_KEY\": \(key)\n"
        #expect(DeepSeekHarnessCredentialReader.apiKey(fromCredentialsYAML: quotedKey) == key)
        let crlf = "\u{FEFF}version: 1\r\nrefs:\r\n  DEEPSEEK_API_KEY: \(key)\r\n"
        #expect(DeepSeekHarnessCredentialReader.apiKey(fromCredentialsYAML: crlf) == key)
    }

    @Test("Unknown or ambiguous documents never yield a key")
    func rejectsUnsupportedDocuments() {
        let key = Self.fixtureKey
        let rejected = [
            // Missing or unknown version.
            "refs:\n  DEEPSEEK_API_KEY: \(key)\n",
            "version: 2\nrefs:\n  DEEPSEEK_API_KEY: \(key)\n",
            // Flow mapping, block scalar, anchors and empty values.
            "version: 1\nrefs: {DEEPSEEK_API_KEY: \(key)}\n",
            "version: 1\nrefs:\n  DEEPSEEK_API_KEY: |\n    \(key)\n",
            "version: 1\nrefs:\n  DEEPSEEK_API_KEY: &k \(key)\n",
            "version: 1\nrefs:\n  DEEPSEEK_API_KEY:\n",
            // Duplicate keys are a DSH load error; do not pick one.
            "version: 1\nrefs:\n  DEEPSEEK_API_KEY: \(key)\n  DEEPSEEK_API_KEY: sk-second\n",
            // Unterminated quotes and embedded whitespace.
            "version: 1\nrefs:\n  DEEPSEEK_API_KEY: '\(key)\n",
            "version: 1\nrefs:\n  DEEPSEEK_API_KEY: \"sk-a b\"\n",
            // Tab indentation is not valid YAML.
            "version: 1\nrefs:\n\tDEEPSEEK_API_KEY: \(key)\n"
        ]
        for document in rejected {
            #expect(DeepSeekHarnessCredentialReader.apiKey(fromCredentialsYAML: document) == nil)
        }
    }

    @Test("Only the refs section counts, not nested records or other refs")
    func ignoresOtherSections() {
        let document = """
        version: 1
        refs:
          OPENAI_API_KEY: sk-other
          nested:
            DEEPSEEK_API_KEY: sk-nested
        records:
          DEEPSEEK_API_KEY: sk-record
        """
        #expect(DeepSeekHarnessCredentialReader.apiKey(fromCredentialsYAML: document) == nil)
    }

    @Test("Missing home or credential file reads as unavailable")
    func missingFiles() throws {
        let empty = try makeHome(credentials: nil)
        #expect(DeepSeekHarnessCredentialReader(environment: [:], home: empty).load() == nil)
        let none = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(DeepSeekHarnessCredentialReader(environment: [:], home: none).isAvailable == false)
    }

    @Test("Any DeepSeek endpoint override keeps the key away from api.deepseek.com")
    func endpointOverridesBlockReuse() throws {
        let document = credentials(Self.fixtureKey)
        let relayPatch = """
        - id: llm-deepseek
          config:
            baseURL: 'https://relay.example/anthropic'
        """
        let insertedPatch = """
        - insert:
            - id: llm-deepseek-relay
              name: '@deepseek-ai/dsh-llm-deepseek-api-key'
              config:
                baseURL: 'https://relay.example'
        """
        let homes = [
            try makeHome(credentials: document, dotenv: "export DEEPSEEK_BASE_URL='https://relay.example'\n"),
            try makeHome(credentials: document, homePatch: relayPatch),
            try makeHome(credentials: document, profilePatches: ["web": insertedPatch])
        ]
        for home in homes {
            #expect(DeepSeekHarnessCredentialReader(environment: [:], home: home).load() == nil)
        }
        let plain = try makeHome(credentials: document)
        #expect(DeepSeekHarnessCredentialReader(
            environment: ["DEEPSEEK_BASE_URL": "https://relay.example"], home: plain
        ).load() == nil)
    }

    @Test("Other providers' endpoints and unrelated settings do not block reuse")
    func unrelatedConfigurationAllowsReuse() throws {
        let patch = """
        # User patch layer
        - id: llm-deepseek
          config:
            reasoningEffort: high

        - insert:
            - id: llm-relay
              name: '@deepseek-ai/dsh-llm-openai-compatible'
              config:
                baseURL: 'https://relay.example/v1'
        """
        let home = try makeHome(
            credentials: credentials(Self.fixtureKey),
            dotenv: "DEEPSEEK_BASE_URL=\nOPENAI_BASE_URL=https://relay.example\n",
            profilePatches: ["web": patch]
        )
        #expect(DeepSeekHarnessCredentialReader(environment: [:], home: home).load() == Self.fixtureKey)
    }

    @Test("Detection reports DeepSeek as connected through the DSH key")
    @MainActor
    func detection() throws {
        let home = try makeHome(credentials: credentials(Self.fixtureKey))
        let deepseek = TrackedProvidersStore.detections(home: home, environment: [:], applicationDirectories: [])
            .first { $0.provider == .deepseek }
        #expect(deepseek?.installed == true)
    }
}

@Suite("Local usage source catalog")
struct LocalUsageSourceCatalogNamingTests {
    @Test("ccusage's Antigravity, Grok Build CLI and ZCode sources have names and a stable order")
    func namesNewCCUsageSources() {
        #expect(LocalUsageSourceCatalog.displayName(for: "antigravity") == "Antigravity")
        #expect(LocalUsageSourceCatalog.displayName(for: " Grok ") == "Grok Build CLI")
        #expect(LocalUsageSourceCatalog.displayName(for: "zcode") == "ZCode")
        let ordered = ["trae-agent", "zcode", "future-agent", "grok", "antigravity", "gemini"]
            .sorted { LocalUsageSourceCatalog.sortKey($0) < LocalUsageSourceCatalog.sortKey($1) }
        #expect(ordered == ["gemini", "antigravity", "grok", "zcode", "trae-agent", "future-agent"])
    }
}
