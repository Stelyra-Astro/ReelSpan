import Foundation
import Combine
import StoreKit

@MainActor
final class PurchaseManager: ObservableObject {
    static let productID = "com.reelatlas.fullaccess"

    @Published var product: Product?
    @Published var isUnlocked = false
    @Published var statusMessage = ""
    @Published var hasLoaded = false

    func load() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product == nil { statusMessage = L10n.text("purchase.product_not_configured") }
        } catch {
            statusMessage = L10n.text("purchase.product_not_configured")
        }
        await refreshEntitlement()
        hasLoaded = true
    }

    func purchase() async {
        guard let product else {
            statusMessage = L10n.text("purchase.configure_product")
            return
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    isUnlocked = true
                    statusMessage = L10n.text("purchase.unlocked")
                }
            case .pending:
                statusMessage = L10n.text("purchase.pending")
            case .userCancelled:
                statusMessage = L10n.text("purchase.cancelled")
            @unknown default:
                break
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            statusMessage = isUnlocked ? L10n.text("purchase.restored") : L10n.text("purchase.not_found")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshEntitlement() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }
}
