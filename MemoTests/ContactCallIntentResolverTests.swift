import Testing
@testable import Memo

struct ContactCallIntentResolverTests {

    private let contacts = [
        CareContact(relation: "女儿", realName: "Annie", phoneNumber: "123", aliases: "安妮"),
        CareContact(relation: "儿子", realName: "Leo", phoneNumber: "456", aliases: "")
    ]

    @Test func matchByRelationWithCallVerb() {
        let intent = ContactCallIntentResolver.resolve(
            text: "帮我联系我女儿",
            contacts: contacts
        )
        #expect(intent?.contact.realName == "Annie")
    }

    @Test func matchByRealNameCaseInsensitive() {
        let intent = ContactCallIntentResolver.resolve(
            text: "请帮我打电话给 ANNIE",
            contacts: contacts
        )
        #expect(intent?.contact.realName == "Annie")
    }

    @Test func noMatchWithoutCallIntent() {
        let intent = ContactCallIntentResolver.resolve(
            text: "我女儿今天来看我吗",
            contacts: contacts
        )
        #expect(intent == nil)
    }

    @Test func noMatchWhenContactBookEmpty() {
        let intent = ContactCallIntentResolver.resolve(
            text: "联系我女儿",
            contacts: []
        )
        #expect(intent == nil)
    }
}
