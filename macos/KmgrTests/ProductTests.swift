import Testing
@testable import KmgrCore

@Test func productIdentityIsStable() {
    #expect(Product.name == "kmgr")
    #expect(Product.applicationName == "Kmgr")
    #expect(Product.bundleIdentifier == "com.pktium.kmgr")
}
