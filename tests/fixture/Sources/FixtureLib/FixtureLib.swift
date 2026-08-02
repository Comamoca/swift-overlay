import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public func fixtureGreeting() -> String {
    let payload = try! JSONEncoder().encode(["hello": "fixture"])
    let json = String(data: payload, encoding: .utf8)!
    #if canImport(FoundationNetworking)
    let request = URLRequest(url: URL(string: "https://swift.org")!)
    precondition(request.httpMethod == "GET")
    #endif
    return "fixture-ok \(json)"
}
