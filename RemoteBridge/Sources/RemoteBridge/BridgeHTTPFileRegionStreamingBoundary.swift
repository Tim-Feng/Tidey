import NIOCore
import NIOHTTP1

/// One HTTP response whose body is already authorized as a response-specific
/// descriptor and byte interval. The caller must not reuse `fileHandle`; this
/// value transfers its ownership to `BridgeHTTPFileRegionResponseWriter`.
struct BridgeHTTPFileRegionResponse {
    let head: HTTPResponseHead
    let fileHandle: NIOFileHandle
    let readerIndex: Int
    let endIndex: Int

    init(head: HTTPResponseHead,
         fileHandle: NIOFileHandle,
         readerIndex: Int,
         endIndex: Int) {
        precondition(readerIndex >= 0)
        precondition(endIndex >= readerIndex)
        self.head = head
        self.fileHandle = fileHandle
        self.readerIndex = readerIndex
        self.endIndex = endIndex
    }
}

/// Emits one `FileRegion` write and lets the channel's outbound buffer own
/// socket writability/backpressure. The descriptor remains alive until both
/// the body write and terminating HTTP part have completed or failed.
struct BridgeHTTPFileRegionResponseWriter {
    func write(_ response: BridgeHTTPFileRegionResponse,
               to channel: Channel) -> EventLoopFuture<Void> {
        let headPart = HTTPServerResponsePart.head(response.head)
        channel.write(headPart, promise: nil)

        let region = FileRegion(fileHandle: response.fileHandle,
                                readerIndex: response.readerIndex,
                                endIndex: response.endIndex)
        let bodyPromise = channel.eventLoop.makePromise(of: Void.self)
        let bodyPart = HTTPServerResponsePart.body(.fileRegion(region))
        channel.write(bodyPart, promise: bodyPromise)

        let endPart = HTTPServerResponsePart.end(nil)
        let endFuture = channel.writeAndFlush(endPart)
        let completion = bodyPromise.futureResult.and(endFuture).map { _ in () }
        completion.whenComplete { _ in
            try? response.fileHandle.close()
        }
        return completion
    }
}
