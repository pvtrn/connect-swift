import Foundation

/// Stream implementation that wraps a `URLSession` stream.
final class URLSessionStream: NSObject {
    private var closedByServer = false
    private let responseCallbacks: ResponseCallbacks
    private let task: URLSessionUploadTask
    private let writeStream: Foundation.OutputStream

    enum Error: Swift.Error {
        case unableToFindBaseAddress
        case unableToWriteData
    }

    init(
        request: URLRequest,
        session: URLSession,
        responseCallbacks: ResponseCallbacks
    ) {
        var readStream: Foundation.InputStream!
        var writeStream: Foundation.OutputStream!
        Foundation.Stream.getBoundStreams(
            withBufferSize: 2 * (1_024 * 1_024),
            inputStream: &readStream,
            outputStream: &writeStream
        )

        self.responseCallbacks = responseCallbacks
        self.writeStream = writeStream

        var request = request
        request.httpBodyStream = readStream

        self.task = session.uploadTask(withStreamedRequest: request)
        super.init()

        self.task.delegate = self
        writeStream.schedule(in: .current, forMode: .default)
        writeStream.open()
        self.task.resume()
    }

    func sendData(_ data: Data) throws {
        var remaining = Data(data)
        while !remaining.isEmpty {
            let bytesWritten = try remaining.withUnsafeBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else {
                    throw Error.unableToFindBaseAddress
                }

                return self.writeStream.write(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    maxLength: remaining.count
                )
            }

            if bytesWritten >= 0 {
                remaining = remaining.dropFirst(bytesWritten)
            } else {
                throw Error.unableToWriteData
            }
        }
    }

    func close() {
        self.writeStream.close()
    }
}

extension URLSessionStream: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    {
        defer { completionHandler(.allow) }

        guard let httpURLResponse = response as? HTTPURLResponse else {
            return
        }

        let code = Code.fromURLSessionCode(httpURLResponse.statusCode)
        self.responseCallbacks.receiveResponseHeaders(
            httpURLResponse.formattedLowercasedHeaders()
        )
        if code != .ok {
            self.closedByServer = true
            self.responseCallbacks.receiveClose(code, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !self.closedByServer {
            self.responseCallbacks.receiveResponseData(data)
        }
    }
}

extension URLSessionStream: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?
    ) {
        if self.closedByServer {
            return
        }

        self.closedByServer = true
        if let error = error {
            self.responseCallbacks.receiveClose(
                Code.fromURLSessionCode((error as NSError).code), error
            )
        } else {
            self.responseCallbacks.receiveClose(.ok, nil)
        }
    }
}
