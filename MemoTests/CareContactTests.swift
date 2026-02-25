import Testing
@testable import Memo

struct CareContactTests {

    @Test func displayNameWithRelationAndRealName() {
        let c = CareContact(relation: "女儿", realName: "Annie", phoneNumber: "123")
        #expect(c.displayName == "女儿（Annie）")
    }

    @Test func confirmationNameWithRelationAndRealName() {
        let c = CareContact(relation: "女儿", realName: "Annie", phoneNumber: "123")
        #expect(c.confirmationName == "你的女儿（Annie）")
    }

    @Test func searchableNamesIncludeAliases() {
        let c = CareContact(
            relation: "女儿",
            realName: "Annie",
            phoneNumber: "123",
            aliases: "安妮,annie, 小安"
        )
        let names = Set(c.searchableNames)
        #expect(names.contains("女儿"))
        #expect(names.contains("Annie"))
        #expect(names.contains("安妮"))
        #expect(names.contains("annie"))
        #expect(names.contains("小安"))
    }

    @Test func dialableNumberStripsFormatting() {
        let c = CareContact(relation: "女儿", realName: "Annie", phoneNumber: "+64 21-123 4567")
        #expect(c.dialableNumber == "+64211234567")
    }
}
