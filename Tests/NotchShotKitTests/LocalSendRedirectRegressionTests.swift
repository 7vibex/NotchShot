import Foundation
import Testing
@testable import NotchShotKit

@Suite("LocalSend redirect delegate regression")
struct LocalSendRedirectRegressionTests {
    private static var redirectSelector: Selector {
        #selector(URLSessionTaskDelegate.urlSession(
            _:task:willPerformHTTPRedirection:newRequest:completionHandler:
        ))
    }

    @Test("Foundation can dispatch the redirect refusal through its protocol", arguments: [307, 308])
    func redirectCallbackIsExposed(statusCode: Int) async throws {
        let delegate = LocalSendTrustDelegate(expectedFingerprint: nil)
        try #require(delegate.responds(to: Self.redirectSelector))

        let source = try #require(URL(string: "https://receiver.invalid/upload"))
        let destination = try #require(URL(string: "https://redirect.invalid/upload"))
        let response = try #require(HTTPURLResponse(
            url: source, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Location": destination.absoluteString]
        ))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // The task stays suspended. Invoke the optional protocol callback
        // directly; this test never opens a connection or starts a receiver.
        let task = session.dataTask(with: source)
        let protocolDelegate: any URLSessionTaskDelegate = delegate
        let allowed: URLRequest? = await withCheckedContinuation { continuation in
            protocolDelegate.urlSession?(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { request in
                continuation.resume(returning: request)
            }
        }
        #expect(allowed == nil)
    }
}
