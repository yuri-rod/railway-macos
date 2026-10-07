import Foundation
import CryptoKit

public struct StorageBucket: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
}
public struct BucketCredentials: Decodable, Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let bucketName: String
    public let endpoint: String
    public let region: String
    public let urlStyle: String
}
public struct BucketObject: Identifiable, Sendable {
    public let key: String
    public let size: Int64
    public let modified: String
    public var id: String { key }
}
public struct BucketPage: Sendable { public let objects: [BucketObject]; public let cursor: String? }
extension RailwayAPI {
    public func buckets(project: String) async throws -> [StorageBucket] {
        struct Result: Decodable { struct Project: Decodable { let buckets: Connection<StorageBucket> }; let project: Project }
        let result: Result = try await query("query($id:String!) { project(id:$id) { buckets(first:100) { edges { node { id name } } } } }", variables: ["id": project])
        return result.project.buckets.nodes
    }
    public func bucketCredentials(project: String, environment: String, bucket: String) async throws -> BucketCredentials {
        struct Result: Decodable { let bucketS3Credentials: [BucketCredentials] }
        let result: Result = try await query("query($project:String!,$environment:String!,$bucket:String!) { bucketS3Credentials(projectId:$project,environmentId:$environment,bucketId:$bucket) { accessKeyId secretAccessKey bucketName endpoint region urlStyle } }", variables: ["project": project, "environment": environment, "bucket": bucket])
        guard let credential = result.bucketS3Credentials.first else { throw RailwayError.api("This bucket has no available credentials in this environment.") }
        return credential
    }
}
public struct BucketReader: Sendable {
    private let credentials: BucketCredentials
    public init(credentials: BucketCredentials) { self.credentials = credentials }
    public static func encode(_ value: String, preserveSlash: Bool = false) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~" + (preserveSlash ? "/" : "")))!
    }
    public func request(key: String = "", parameters: [String: String] = [:], date: Date = Date()) throws -> URLRequest {
        guard var url = URLComponents(string: credentials.endpoint), url.scheme == "https", let host = url.host,
              host == "t3.storageapi.dev" || host.hasSuffix(".storageapi.dev"), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else { throw RailwayError.api("Unrecognized Railway storage endpoint.") }
        guard credentials.bucketName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }), !credentials.bucketName.isEmpty else { throw RailwayError.api("Invalid storage bucket name.") }
        guard !key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw RailwayError.api("This object key contains unsupported relative path segments.") }
        let pathStyle = credentials.urlStyle.lowercased().contains("path")
        if !pathStyle { url.host = credentials.bucketName + "." + host }
        url.percentEncodedPath = "/" + (pathStyle ? Self.encode(credentials.bucketName) + "/" : "") + Self.encode(key, preserveSlash: true)
        let pairs: [(String, String)] = parameters.map { (Self.encode($0.key), Self.encode($0.value)) }
        let sorted = pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let query = sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        url.percentEncodedQuery = query.isEmpty ? nil : query
        guard let target = url.url else { throw RailwayError.api("Invalid storage URL.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date), day = String(stamp.prefix(8))
        let hash = Self.hash(Data())
        let headers = "host:\(url.host!)\nx-amz-content-sha256:\(hash)\nx-amz-date:\(stamp)\n"
        let signed = "host;x-amz-content-sha256;x-amz-date"
        let canonical = "GET\n\(url.percentEncodedPath)\n\(query)\n\(headers)\n\(signed)\n\(hash)"
        let scope = "\(day)/\(credentials.region)/s3/aws4_request"
        let string = "AWS4-HMAC-SHA256\n\(stamp)\n\(scope)\n\(Self.hash(Data(canonical.utf8)))"
        var signing = Data(("AWS4" + credentials.secretAccessKey).utf8)
        for part in [day, credentials.region, "s3", "aws4_request"] { signing = Self.hmac(signing, part) }
        let signature = Self.hmac(signing, string).map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: target); request.timeoutInterval = 30
        request.setValue(hash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signed), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }
    public func list(prefix: String, cursor: String? = nil) async throws -> BucketPage {
        var params = ["list-type": "2", "max-keys": "200", "prefix": prefix]; params["continuation-token"] = cursor
        let data = try await read(try request(parameters: params), maximum: 4_000_000)
        guard data.range(of: Data("<!DOCTYPE".utf8)) == nil, data.range(of: Data("<!ENTITY".utf8)) == nil else { throw RailwayError.api("The bucket returned an unsupported XML declaration.") }
        let delegate = ObjectListing()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw RailwayError.api("The bucket returned an invalid object listing.") }
        guard delegate.cursor == nil || delegate.cursor != cursor else { throw RailwayError.api("The bucket repeated its pagination cursor.") }
        return BucketPage(objects: delegate.objects, cursor: delegate.cursor)
    }
    public func preview(key: String) async throws -> Data { try await read(try request(key: key), maximum: 2_000_000) }
    private func read(_ request: URLRequest, maximum: Int) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RailwayError.api("Bucket access failed. Check your storage permissions.") }
        guard response.expectedContentLength <= maximum else { throw RailwayError.api("Storage response exceeds the allowed size limit.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw RailwayError.api("Storage response exceeded the size limit.") }
            data.append(byte)
        }
        return data
    }
}
private final class ObjectListing: NSObject, XMLParserDelegate {
    var objects: [BucketObject] = []
    var cursor: String?
    private var text = "", key = "", size: Int64 = 0, modified = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        if elementName == "Contents" { key = ""; size = 0; modified = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Key": key = text
        case "Size": size = Int64(text) ?? 0
        case "LastModified": modified = text
        case "NextContinuationToken": cursor = text.isEmpty ? nil : text
        case "Contents": objects.append(BucketObject(key: key, size: size, modified: modified))
        default: break
        }
        text = ""
    }
}
