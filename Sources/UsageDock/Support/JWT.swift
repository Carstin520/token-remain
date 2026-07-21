import Foundation

/// 最小 JWT 声明读取:只做 base64url 解码取 payload,不验签——
/// 我们只用它对本机已有 token 做过期预检,真正的鉴权由服务端完成。
enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = (payload(token)?["exp"] as? NSNumber)?.doubleValue, exp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}
