import Foundation

final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum NoRedirectURLSession {
    static func make(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }
}
