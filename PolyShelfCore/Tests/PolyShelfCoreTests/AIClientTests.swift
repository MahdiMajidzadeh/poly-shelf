import XCTest
@testable import PolyShelfCore

final class AIClientTests: XCTestCase {
    func testEndpointURLNormalization() {
        XCTAssertEqual(
            AIEndpointConfig(baseURL: "http://localhost:11434", model: "m").chatCompletionsURL?.absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            AIEndpointConfig(baseURL: "https://api.openai.com/v1/", model: "m").chatCompletionsURL?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            AIEndpointConfig(baseURL: "https://proxy.example/v1/chat/completions", model: "m").chatCompletionsURL?.absoluteString,
            "https://proxy.example/v1/chat/completions"
        )
    }

    func testParseCleanJSON() throws {
        let content = #"{"tags": ["Articulated", "dragon"], "description": "A flexi dragon.", "suggested_display_name": "Flexi Dragon"}"#
        let result = try AIClient.parseResult(content)
        XCTAssertEqual(result.tags, ["articulated", "dragon"], "tags normalized to lowercase")
        XCTAssertEqual(result.suggestedDisplayName, "Flexi Dragon")
    }

    func testParseFencedJSON() throws {
        let content = """
        ```json
        {"tags": ["vase"], "description": null, "suggested_display_name": null}
        ```
        """
        let result = try AIClient.parseResult(content)
        XCTAssertEqual(result.tags, ["vase"])
    }

    func testParseJSONWithLeadingProse() throws {
        let content = #"Sure! Here you go: {"tags": ["benchy"], "description": "d", "suggested_display_name": "n"}"#
        XCTAssertEqual(try AIClient.parseResult(content).tags, ["benchy"])
    }

    func testMalformedContentThrows() {
        XCTAssertThrowsError(try AIClient.parseResult("I cannot analyze this image."))
        XCTAssertThrowsError(try AIClient.parseResult(#"{"tags": []}"#), "empty tags rejected")
    }

    func testExtractContentFromChatCompletion() throws {
        let response = #"{"choices": [{"message": {"role": "assistant", "content": "{\"tags\": [\"x\"]}"}}]}"#
        XCTAssertEqual(try AIClient.extractContent(Data(response.utf8)), #"{"tags": ["x"]}"#)
        XCTAssertThrowsError(try AIClient.extractContent(Data(#"{"error": "boom"}"#.utf8)))
    }

    func testRequestCarriesNoKeyInURLOrBody() throws {
        let client = AIClient(
            config: AIEndpointConfig(baseURL: "http://localhost:1234", model: "test-model"),
            apiKeyOverride: "sk-supersecret-123456"
        )
        let request = try client.buildRequest(filename: "a.stl", stats: "Format: .stl", previewPNG: nil)
        XCTAssertFalse(request.url!.absoluteString.contains("supersecret"), "key must not be in URL")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertFalse(body.contains("supersecret"), "key must not be in body")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-supersecret-123456")
    }

    func testRequestIncludesImageWhenProvided() throws {
        let client = AIClient(
            config: AIEndpointConfig(baseURL: "http://localhost:1234", model: "m"),
            apiKeyOverride: nil
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let request = try client.buildRequest(filename: "a.stl", stats: "s", previewPNG: png)
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("data:image/png;base64,"))
        XCTAssertTrue(body.contains(png.base64EncodedString()))
    }
}
