import Foundation
import XCTest
@testable import iPhoneLocalAI

final class HuggingFaceTests: XCTestCase {
    func testSearchResultsDecodeWithMixedGatedValues() throws {
        let json = #"""
        [
          {"id": "ggml-org/gemma-4-E2B-it-GGUF", "downloads": 1200, "likes": 34, "gated": false},
          {"id": "google/gemma-4-e2b-it", "downloads": 5, "gated": "manual"},
          {"id": "someone/minimal"}
        ]
        """#
        let models = try JSONDecoder().decode([HuggingFaceModelSummary].self, from: Data(json.utf8))
        XCTAssertEqual(models, [
            HuggingFaceModelSummary(id: "ggml-org/gemma-4-E2B-it-GGUF", downloads: 1200, likes: 34, gated: false),
            HuggingFaceModelSummary(id: "google/gemma-4-e2b-it", downloads: 5, likes: 0, gated: true),
            HuggingFaceModelSummary(id: "someone/minimal")
        ])
    }

    func testFileListKeepsModelFilesAndPutsProjectorsLast() throws {
        let json = #"""
        [
          {"type": "file", "path": "README.md", "size": 1200},
          {"type": "directory", "path": "onnx", "size": 0},
          {"type": "file", "path": "mmproj-model-Q8_0.gguf", "size": 135, "lfs": {"size": 532000000}},
          {"type": "file", "path": "model-Q8_0.gguf", "size": 135, "lfs": {"size": 4700000000}},
          {"type": "file", "path": "sub/model-Q4_0.GGUF", "size": 135, "lfs": {"size": 2700000000}},
          {"type": "file", "path": "model.litertlm", "size": 2588147712}
        ]
        """#
        let files = try HuggingFaceClient.decodeFiles(Data(json.utf8))
        XCTAssertEqual(files.map(\.path), ["model.litertlm", "sub/model-Q4_0.GGUF", "model-Q8_0.gguf", "mmproj-model-Q8_0.gguf"])
        XCTAssertEqual(files.map(\.sizeBytes), [2_588_147_712, 2_700_000_000, 4_700_000_000, 532_000_000])
        XCTAssertEqual(files[1].fileName, "model-Q4_0.GGUF")
        XCTAssertEqual(files[1].baseName, "model-Q4_0")
        XCTAssertEqual(files.map(\.isProjector), [false, false, false, true])
    }

    func testURLsAreBuiltOnlyForValidRepositoriesAndModelFiles() {
        XCTAssertEqual(
            HuggingFaceClient.downloadURL(repository: "Qwen/Qwen2.5-0.5B-Instruct-GGUF", path: "sub dir/model q4.gguf")?.absoluteString,
            "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/sub%20dir/model%20q4.gguf"
        )
        XCTAssertEqual(
            HuggingFaceClient.treeURL(repository: "ggml-org/gemma-4-E2B-it-GGUF")?.absoluteString,
            "https://huggingface.co/api/models/ggml-org/gemma-4-E2B-it-GGUF/tree/main?recursive=true"
        )
        XCTAssertNil(HuggingFaceClient.downloadURL(repository: "no-owner", path: "model.gguf"))
        XCTAssertNil(HuggingFaceClient.downloadURL(repository: "owner/name/extra", path: "model.gguf"))
        XCTAssertNil(HuggingFaceClient.downloadURL(repository: "owner/name", path: "../model.gguf"))
        XCTAssertNil(HuggingFaceClient.downloadURL(repository: "owner/name", path: "config.json"))
        XCTAssertNil(HuggingFaceClient.downloadURL(repository: "owner/name", revision: "a/b", path: "model.gguf"))

        let search = HuggingFaceClient.searchURL(query: " gemma 4 ", ggufOnly: true)
        let items = URLComponents(url: search!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "search", value: "gemma 4")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "filter", value: "gguf")))
        let all = HuggingFaceClient.searchURL(query: "", ggufOnly: false)
        XCTAssertEqual(URLComponents(url: all!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["sort", "direction", "limit"])
    }

    func testFitEstimateComparesFileSizeWithDeviceMemory() {
        let eightGigabytes: UInt64 = 8 * 1_073_741_824
        XCTAssertEqual(ModelFit.estimate(sizeBytes: 2_800_000_000, physicalMemory: eightGigabytes), .comfortable)
        XCTAssertEqual(ModelFit.estimate(sizeBytes: 4_700_000_000, physicalMemory: eightGigabytes), .tight)
        XCTAssertEqual(ModelFit.estimate(sizeBytes: 8_700_000_000, physicalMemory: eightGigabytes), .tooLarge)
    }

    @MainActor
    func testDownloaderRejectsFilesThatAreNotModels() {
        let downloader = ModelDownloader()
        for (repository, path) in [("owner/name", "notes.txt"), ("not a repository", "model.gguf")] {
            do {
                try downloader.enqueue(repository: repository, path: path, sizeBytes: 10)
                XCTFail("Expected \(repository)/\(path) to be rejected")
            } catch {
                XCTAssertEqual(error as? HuggingFaceError, .invalidRepository)
            }
        }
        XCTAssertTrue(downloader.downloads.isEmpty)
    }
}
