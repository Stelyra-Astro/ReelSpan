import Foundation

enum AppConfiguration {
    #if DEBUG
    static let bypassPurchaseForDevelopment = true
    #else
    static let bypassPurchaseForDevelopment = false
    #endif
}
