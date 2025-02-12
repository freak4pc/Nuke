// The MIT License (MIT)
//
// Copyright (c) 2015-2022 Alexander Grebenyuk (github.com/kean).

import XCTest
@testable import Nuke

class ImagePipelineCoalescingTests: XCTestCase {
    var dataLoader: MockDataLoader!
    var pipeline: ImagePipeline!
    var observations = [NSKeyValueObservation]()

    override func setUp() {
        super.setUp()

        dataLoader = MockDataLoader()
        pipeline = ImagePipeline {
            $0.dataLoader = dataLoader
            $0.imageCache = nil
        }
    }

    // MARK: - Deduplication

    func testDeduplicationGivenSameURLDifferentSameProcessors() {
        dataLoader.queue.isSuspended = true

        // Given requests with the same URLs and same processors
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])

        // When loading images for those requests
        // Then the correct proessors are applied.
        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }

        dataLoader.queue.isSuspended = false

        wait { _ in
            // Then the original image is loaded once, and the image is processed
            // also only once
            XCTAssertEqual(processors.numberOfProcessorsApplied, 1)
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1)
        }
    }

    func testDeduplicationGivenSameURLDifferentProcessors() {
        dataLoader.queue.isSuspended = true

        // Given requests with the same URLs but different processors
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "2")])

        // When loading images for those requests
        // Then the correct proessors are applied.
        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["2"])
        }

        dataLoader.queue.isSuspended = false

        wait { _ in
            // Then the original image is loaded once, but both processors are applied
            XCTAssertEqual(processors.numberOfProcessorsApplied, 2)
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1)
        }
    }

    func testDeduplicationGivenSameURLDifferentProcessorsOneEmpty() {
        dataLoader.queue.isSuspended = true

        // Given requests with the same URLs but different processors where one
        // processor is empty
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])

        var request2 = Test.request
        request2.processors = []

        // When loading images for those requests
        // Then the correct proessors are applied.
        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], [])
        }

        dataLoader.queue.isSuspended = false

        wait { _ in
            // Then
            // The original image is loaded once, the first processor is applied
            XCTAssertEqual(processors.numberOfProcessorsApplied, 1)
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1)
        }
    }

    func testNoDeduplicationGivenNonEquivalentRequests() {
        dataLoader.queue.isSuspended = true

        let request1 = ImageRequest(urlRequest: URLRequest(url: Test.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 0))
        let request2 = ImageRequest(urlRequest: URLRequest(url: Test.url, cachePolicy: .returnCacheDataDontLoad, timeoutInterval: 0))

        expect(pipeline).toLoadImage(with: request1)
        expect(pipeline).toLoadImage(with: request2)

        dataLoader.queue.isSuspended = false

        wait { _ in
            XCTAssertEqual(self.dataLoader.createdTaskCount, 2)
        }
    }
    
    // MARK: - Thumbnail
    
    func testDeduplicationGivenSameURLButDifferentThumbnailOptions() {
        dataLoader.queue.isSuspended = true

        // GIVEN requests with the same URLs but one accesses thumbnail
        let request1 = ImageRequest(url: Test.url, userInfo: [.thumbnailKey: ImageRequest.ThumbnailOptions(maxPixelSize: 400)])
        let request2 = ImageRequest(url: Test.url)

        // WHEN loading images for those requests
        expect(pipeline).toLoadImage(with: request1) { result in
            // THEN
            guard let image = result.value?.image else { return XCTFail() }
            XCTAssertEqual(image.sizeInPixels, CGSize(width: 400, height: 300))
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            // THEN
            guard let image = result.value?.image else { return XCTFail() }
            XCTAssertEqual(image.sizeInPixels, CGSize(width: 640.0, height: 480.0))
        }

        dataLoader.queue.isSuspended = false

        wait { _ in
            // THEN the image data is fetched once
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1)
        }
    }

    // MARK: - Processing

    func testProcessorsAreDeduplicated() {
        dataLoader.queue.isSuspended = true

        // Given
        // Make sure we don't start processing when some requests haven't
        // started yet.
        let processors = MockProcessorFactory()
        let queueObserver = OperationQueueObserver(queue: pipeline.configuration.imageProcessingQueue)

        // When
        expect(pipeline).toLoadImage(with: ImageRequest(url: Test.url, processors: [processors.make(id: "1")]))
        expect(pipeline).toLoadImage(with: ImageRequest(url: Test.url, processors: [processors.make(id: "2")]))
        expect(pipeline).toLoadImage(with: ImageRequest(url: Test.url, processors: [processors.make(id: "1")]))

        dataLoader.queue.isSuspended = false

        // When/Then
        wait { _ in
            XCTAssertEqual(queueObserver.operations.count, 2)
            XCTAssertEqual(processors.numberOfProcessorsApplied, 2)
        }
    }

    func testSubscribingToExisingSessionWhenProcessingAlreadyStarted() {
        // Given
        let queue = pipeline.configuration.imageProcessingQueue
        queue.isSuspended = true

        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])

        let queueObserver = OperationQueueObserver(queue: queue)

        let expectation = self.expectation(description: "Second request completed")

        queueObserver.didAddOperation = { operation in
            queueObserver.didAddOperation = nil

            // When loading image with the same request and processing for
            // the first request has already started
            self.pipeline.loadImage(with: request2) { result in
                let image = result.value?.image
                // Then the image is still loaded and processors is applied
                XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
                expectation.fulfill()
            }
            queue.isSuspended = false
        }

        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }

        wait { _ in
            // Then the original image is loaded only once, but processors are
            // applied twice
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1)
            XCTAssertEqual(processors.numberOfProcessorsApplied, 1)
            XCTAssertEqual(queueObserver.operations.count, 1)
        }
    }

    func testCorrectImageIsStoredInMemoryCache() {
        let imageCache = MockImageCache()
        let pipeline = ImagePipeline {
            $0.dataLoader = dataLoader
            $0.imageCache = imageCache
        }

        // Given requests with the same URLs but different processors
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "2")])

        // When loading images for those requests
        // Then the correct proessors are applied.
        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["2"])
        }
        wait()

        // Then
        XCTAssertNotNil(imageCache[request1])
        XCTAssertEqual(imageCache[request1]?.image.nk_test_processorIDs ?? [], ["1"])
        XCTAssertNotNil(imageCache[request2])
        XCTAssertEqual(imageCache[request2]?.image.nk_test_processorIDs ?? [], ["2"])
    }

    // MARK: - Cancellation

    func testCancellation() {
        dataLoader.queue.isSuspended = true

        // Given two equivalent requests

        // When both tasks are cancelled the image loading session is cancelled

        _ = expectNotification(MockDataLoader.DidStartTask, object: dataLoader)
        let task1 = pipeline.loadImage(with: Test.request) { _ in }
        let task2 = pipeline.loadImage(with: Test.request) { _ in }
        wait() // wait until the tasks is started or we might be cancelling non-exisitng task

        _ = expectNotification(MockDataLoader.DidCancelTask, object: dataLoader)
        task1.cancel()
        task2.cancel()
        wait()
    }

    func testCancellatioOnlyCancelOneTask() {
        dataLoader.queue.isSuspended = true

        let task1 = pipeline.loadImage(with: Test.request) { _ in
            XCTFail()
        }

        expect(pipeline).toLoadImage(with: Test.request)

        // When cancelling only only only one of the tasks
        task1.cancel()

        // Then the image is still loaded

        dataLoader.queue.isSuspended = false

        wait()
    }

    func testProcessingOperationsAreCancelledSeparately() {
        dataLoader.queue.isSuspended = true

        // Given
        let queue = pipeline.configuration.imageProcessingQueue
        queue.isSuspended = true

        // When/Then
        let operations = expect(queue).toEnqueueOperationsWithCount(2)

        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "2")])

        let _ = pipeline.loadImage(with: request1) { _ in }
        let task2 = pipeline.loadImage(with: request2) { _ in }

        dataLoader.queue.isSuspended = false

        wait()

        // When/Then
        let expectation = self.expectation(description: "One operation got cancelled")
        for operation in operations.operations {
            // Pass the same expectation into both operations, only
            // one should get cancelled.
            expect(operation).toCancel(with: expectation)
        }

        task2.cancel()
        wait()
    }

    // MARK: - Priority

    func testProcessingOperationPriorityUpdated() {
        // Given
        dataLoader.queue.isSuspended = true
        let queue = pipeline.configuration.imageProcessingQueue
        queue.isSuspended = true

        // Given
        let operations = expect(queue).toEnqueueOperationsWithCount(1)

        pipeline.loadImage(with: ImageRequest(url: Test.url, processors: [MockImageProcessor(id: "1")], priority: .low)) { _ in }

        dataLoader.queue.isSuspended = false
        wait { _ in
            XCTAssertEqual(operations.operations.first!.queuePriority, .low)
        }

        // When/Then
        expect(operations.operations.first!).toUpdatePriority(from: .low, to: .high)
        let task = pipeline.loadImage(with: ImageRequest(url: Test.url, processors: [MockImageProcessor(id: "1")], priority: .high)) { _ in }
        wait()

        // When/Then
        expect(operations.operations.first!).toUpdatePriority(from: .high, to: .low)
        task.priority = .low
        wait()
    }

    func testProcessingOperationPriorityUpdatedWhenCancellingTask() {
        // Given
        dataLoader.queue.isSuspended = true
        let queue = pipeline.configuration.imageProcessingQueue
        queue.isSuspended = true

        // Given
        let operations = expect(queue).toEnqueueOperationsWithCount(1)
        pipeline.loadImage(with: ImageRequest(url: Test.url, processors: [MockImageProcessor(id: "1")], priority: .low)) { _ in }
        dataLoader.queue.isSuspended = false
        wait()

        // Given
        // Note: adding a second task separately because we should guarantee
        // that both are subscribed by the time we start our test.
        expect(operations.operations.first!).toUpdatePriority(from: .low, to: .high)
        let task = pipeline.loadImage(with: ImageRequest(url: Test.url, processors: [MockImageProcessor(id: "1")], priority: .high)) { _ in }
        wait()

        // When/Then
        expect(operations.operations.first!).toUpdatePriority(from: .high, to: .low)
        task.cancel()
        wait()
    }

    // MARK: - Loading Data

    func testThatLoadsDataOnceWhenLoadingDataAndLoadingImage() {
        dataLoader.queue.isSuspended = true

        expect(pipeline).toLoadImage(with: Test.request)
        expect(pipeline).toLoadData(with: Test.request)

        dataLoader.queue.isSuspended = false
        wait()

        XCTAssertEqual(dataLoader.createdTaskCount, 1)
    }

    // MARK: - Misc

    func testProgressIsReported() {
        // Given
        dataLoader.results[Test.url] = .success(
            (Data(count: 20), URLResponse(url: Test.url, mimeType: "jpeg", expectedContentLength: 20, textEncodingName: nil))
        )
        dataLoader.queue.isSuspended = true

        // When/Then
        for _ in 0..<3 {
            let request = Test.request

            let expectedProgress = expectProgress([(10, 20), (20, 20)])

            pipeline.loadImage(
                with: request,
                progress: { _, completed, total in
                    XCTAssertTrue(Thread.isMainThread)
                    expectedProgress.received((completed, total))
                },
                completion: { _ in }
            )
        }
        dataLoader.queue.isSuspended = false

        wait()
    }

    func testDisablingDeduplication() {
        // Given
        let pipeline = ImagePipeline {
            $0.imageCache = nil
            $0.dataLoader = dataLoader
            $0.isTaskCoalescingEnabled = false
        }

        dataLoader.queue.isSuspended = true

        // When/Then
        let request1 = Test.request
        let request2 = Test.request

        expect(pipeline).toLoadImage(with: request1)
        expect(pipeline).toLoadImage(with: request2)

        pipeline.queue.sync {}
        dataLoader.queue.isSuspended = false

        wait { _ in
            XCTAssertEqual(self.dataLoader.createdTaskCount, 2)
        }
    }
}

class ImagePipelineProcessingDeduplicationTests: XCTestCase {
    var dataLoader: MockDataLoader!
    var pipeline: ImagePipeline!
    var observations = [NSKeyValueObservation]()

    override func setUp() {
        super.setUp()

        dataLoader = MockDataLoader()
        pipeline = ImagePipeline {
            $0.dataLoader = dataLoader
            $0.imageCache = nil
        }
    }

    func testEachProcessingStepIsDeduplicated() {
        // Given requests with the same URLs but different processors
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "1"), processors.make(id: "2")])

        // When
        dataLoader.queue.isSuspended = true
        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1", "2"])
        }

        // Then the processor "1" is only applied once
        dataLoader.queue.isSuspended = false
        wait { _ in
            XCTAssertEqual(processors.numberOfProcessorsApplied, 2)
        }
    }

    func testEachFinalProcessedImageIsStoredInMemoryCache() {
        let cache = MockImageCache()
        var conf = pipeline.configuration
        conf.imageCache = cache
        pipeline = ImagePipeline(configuration: conf)

        // Given requests with the same URLs but different processors
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "1"), processors.make(id: "2"), processors.make(id: "3")])

        // When
        dataLoader.queue.isSuspended = true
        expect(pipeline).toLoadImage(with: request1)
        expect(pipeline).toLoadImage(with: request2)

        // Then
        dataLoader.queue.isSuspended = false
        wait { _ in
            XCTAssertNotNil(cache[request1])
            XCTAssertNotNil(cache[request2])
            XCTAssertNil(cache[ImageRequest(url: Test.url, processors: [processors.make(id: "1"), processors.make(id: "2")])])
        }
    }

    func testWhenApplingMultipleImageProcessorsIntermediateMemoryCachedResultsAreUsed() {
        let cache = MockImageCache()
        var conf = pipeline.configuration
        conf.imageCache = cache
        pipeline = ImagePipeline(configuration: conf)

        let factory = MockProcessorFactory()

        // Given
        cache[ImageRequest(url: Test.url, processors: [factory.make(id: "1"), factory.make(id: "2")])] = Test.container

        // When
        let request = ImageRequest(url: Test.url, processors: [factory.make(id: "1"), factory.make(id: "2"), factory.make(id: "3")])
        expect(pipeline).toLoadImage(with: request) { result in
            guard let image = result.value?.image else {
                return XCTFail("Expected image to be loaded successfully")
            }
            XCTAssertEqual(image.nk_test_processorIDs, ["3"], "Expected only the last processor to be applied")
        }

        // Then
        wait { _ in
            XCTAssertEqual(self.dataLoader.createdTaskCount, 0, "Expected no data task to be performed")
            XCTAssertEqual(factory.numberOfProcessorsApplied, 1, "Expected only one processor to be applied")
        }
    }

    func testWhenApplingMultipleImageProcessorsIntermediateDataCacheResultsAreNotUsed() {
        // Given
        let dataCache = MockDataCache()
        dataCache.store[Test.url.absoluteString + "12"] = Test.data

        pipeline = pipeline.reconfigured {
            $0.dataCache = dataCache
        }

        // When
        let factory = MockProcessorFactory()
        let request = ImageRequest(url: Test.url, processors: [factory.make(id: "1"), factory.make(id: "2"), factory.make(id: "3")])
        expect(pipeline).toLoadImage(with: request) { result in
            guard let image = result.value?.image else {
                return XCTFail("Expected image to be loaded successfully")
            }
            XCTAssertEqual(image.nk_test_processorIDs, ["1", "2", "3"], "Expected only the last processor to be applied")
        }

        // Then we don't expect any intermediate results to be stored in data cache
        wait { _ in
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1, "Expected no data task to be performed")
            XCTAssertEqual(factory.numberOfProcessorsApplied, 3, "Expected only one processor to be applied")
        }
    }

    func testThatProcessingDeduplicationCanBeDisabled() {
        // Given
        pipeline = pipeline.reconfigured {
            $0.isTaskCoalescingEnabled = false
        }

        // Given requests with the same URLs but different processors
        let processors = MockProcessorFactory()
        let request1 = ImageRequest(url: Test.url, processors: [processors.make(id: "1")])
        let request2 = ImageRequest(url: Test.url, processors: [processors.make(id: "1"), processors.make(id: "2")])

        // When
        dataLoader.queue.isSuspended = true
        expect(pipeline).toLoadImage(with: request1) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1"])
        }
        expect(pipeline).toLoadImage(with: request2) { result in
            let image = result.value?.image
            XCTAssertEqual(image?.nk_test_processorIDs ?? [], ["1", "2"])
        }

        // Then the processor "1" is applied twice
        dataLoader.queue.isSuspended = false
        wait { _ in
            XCTAssertEqual(processors.numberOfProcessorsApplied, 3)
        }
    }

    func testThatDataOnlyLoadedOnceWithDifferentCachePolicy() {
        // Given
        let dataCache = MockDataCache()
        pipeline = pipeline.reconfigured {
            $0.dataCache = dataCache
        }
        dataLoader.queue.isSuspended = true

        // When
        func makeRequest(options: ImageRequest.Options) -> ImageRequest {
            ImageRequest(urlRequest: URLRequest(url: Test.url), options: options)
        }
        expect(pipeline).toLoadImage(with: makeRequest(options: []))
        expect(pipeline).toLoadImage(with: makeRequest(options: [.reloadIgnoringCachedData]))
        pipeline.queue.sync {}
        dataLoader.queue.isSuspended = false

        // Then
        wait { _ in
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1, "Expected only one data task to be performed")
        }
    }

    func testThatDataOnlyLoadedOnceWithDifferentCachePolicyPassingURL() {
        // Given
        let dataCache = MockDataCache()
        pipeline = pipeline.reconfigured {
            $0.dataCache = dataCache
        }
        dataLoader.queue.isSuspended = true

        // When
        // - One request reloading cache data, another one not
        func makeRequest(options: ImageRequest.Options) -> ImageRequest {
            ImageRequest(urlRequest: URLRequest(url: Test.url), options: options)
        }
        expect(pipeline).toLoadImage(with: makeRequest(options: []))
        expect(pipeline).toLoadImage(with: makeRequest(options: [.reloadIgnoringCachedData]))
        pipeline.queue.sync {}
        dataLoader.queue.isSuspended = false

        // Then
        wait { _ in
            XCTAssertEqual(self.dataLoader.createdTaskCount, 1, "Expected only one data task to be performed")
        }
    }
}
