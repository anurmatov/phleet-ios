import XCTest

/// `XCTUnwrap` for a value produced by an `await`.
///
/// `XCTUnwrap` takes an autoclosure, and an `await` cannot sit inside one. Written
/// `try await XCTUnwrapAsync(model.connect())`, the `await` covers the call and this receives the
/// value.
func XCTUnwrapAsync<Value>(
    _ value: Value?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Value {
    try XCTUnwrap(value, file: file, line: line)
}
