import Testing

@testable import NotchShotAIReporterSupport

@Suite("AI reporter secret redaction")
struct AIReporterRedactionTests {
    @Test("Header spellings redact credentials but preserve harmless headers")
    func headers() {
        let secret = "Bearer abcDEF1234567890+/=token"
        let redacted = CommandSecretRedactor.redact([
            "curl",
            "-H", "Authorization: \(secret)",
            "--header=Cookie: session=private",
            "-HX-API-Key: private-key",
            "-H", "Content-Type: application/json",
        ])

        #expect(!redacted.joined(separator: " ").contains(secret))
        #expect(redacted.contains("Authorization: <redacted>"))
        #expect(redacted.contains("--header=Cookie: <redacted>"))
        #expect(redacted.contains("-HX-API-Key: <redacted>"))
        #expect(redacted.contains("Content-Type: application/json"))
    }

    @Test("Options, environment assignments, and URL credentials are redacted")
    func structuredValues() {
        let redacted = CommandSecretRedactor.redact([
            "tool", "--token=secret-token", "--user", "person:password",
            "API_KEY=abcdef123456", "https://person:password@example.com/path?token=private&safe=yes",
        ]).joined(separator: " ")

        #expect(!redacted.contains("secret-token"))
        #expect(!redacted.contains("person:password"))
        #expect(!redacted.contains("abcdef123456"))
        #expect(!redacted.contains("token=private"))
        #expect(redacted.contains("safe=yes"))
    }

    @Test("Prompt text suppresses provider tokens")
    func promptText() {
        let secret = "sk-example12345678901234567890"
        let bearer = "abcDEF1234567890+/=token"
        let result = CommandSecretRedactor.redactText(
            "Investigate with \(secret) Authorization: Bearer \(bearer) today"
        )
        #expect(!result.contains(secret))
        #expect(!result.contains(bearer))
        #expect(result.contains("<redacted>"))
    }
}
