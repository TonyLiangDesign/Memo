import Foundation

enum RoomStatus: String, Codable {
    case draft        // 已创建未扫描
    case ready        // 地图可用
    case needsRescan  // 多次重定位失败，建议重扫
}
