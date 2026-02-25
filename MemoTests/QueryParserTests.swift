import Testing
import Foundation
@testable import Memo

struct QueryParserTests {

    // MARK: - 用药查询

    @Test func medicationCheck() {
        #expect(QueryParser.parse("我吃药了吗") == .medicationCheck)
    }

    @Test func medicationCheckVariant() {
        #expect(QueryParser.parse("今天的药吃了没") == .medicationCheck)
    }

    @Test func medicationCheckService() {
        #expect(QueryParser.parse("我服药了吗") == .medicationCheck)
    }

    // MARK: - 近期活动

    @Test func recentActionsGanma() {
        #expect(QueryParser.parse("我刚才干嘛了") == .recentActions)
    }

    @Test func recentActionsToday() {
        #expect(QueryParser.parse("今天做了什么") == .recentActions)
    }

    @Test func recentActionsJustNow() {
        #expect(QueryParser.parse("刚才发生了什么") == .recentActions)
    }

    // MARK: - 未知意图

    @Test func unknownIntent() {
        #expect(QueryParser.parse("你好") == .unknown("你好"))
    }

    @Test func emptyInput() {
        #expect(QueryParser.parse("") == .unknown(""))
    }

    @Test func whitespaceOnly() {
        #expect(QueryParser.parse("   ") == .unknown(""))
    }
}
