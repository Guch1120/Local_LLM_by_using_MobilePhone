import Foundation

enum BearerTokenAuthenticator {
    static func matches(_ authorizationHeader: String?, expectedToken: String) -> Bool {
        guard let authorizationHeader, authorizationHeader.hasPrefix("Bearer ") else { return false }
        let supplied = Array(authorizationHeader.dropFirst(7).utf8)
        let expected = Array(expectedToken.utf8)
        var difference = UInt64(supplied.count ^ expected.count)
        for index in 0..<max(supplied.count, expected.count) {
            let left = index < supplied.count ? supplied[index] : 0
            let right = index < expected.count ? expected[index] : 0
            difference |= UInt64(left ^ right)
        }
        return difference == 0
    }
}
