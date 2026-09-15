import Foundation
import Combine
import StoreKit

@MainActor
final class TipPurchaseManager: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var state: TipState = .unavailable
    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result,
                      transaction.productID == TipRules.productID else { continue }
                await transaction.finish()
                self?.state = .verified
            }
        }
    }
    deinit { updates?.cancel() }

    func load() async {
        guard !state.isBusy else { return }
        state = .loading
        do {
            product = try await Product.products(for: [TipRules.productID]).first { $0.type == .consumable }
            state = product == nil ? .unavailable : .ready
        } catch { state = .failed(error.localizedDescription) }
    }

    func amount(quantity: Int) -> String {
        guard let product, TipRules.isValidQuantity(quantity) else { return "—" }
        return (product.price * Decimal(quantity)).formatted(product.priceFormatStyle)
    }

    func purchase(quantity: Int) async {
        guard TipRules.isValidQuantity(quantity), !state.isBusy else { return }
        guard let product else { state = .unavailable; return }
        state = .purchasing
        do {
            switch try await product.purchase(options: [.quantity(quantity)]) {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    guard transaction.productID == TipRules.productID else { state = .unverified; return }
                    await transaction.finish()
                    state = TipState.result(verified: true)
                case .unverified:
                    state = TipState.result(verified: false)
                }
            case .pending: state = .pending
            case .userCancelled: state = .cancelled
            @unknown default: state = .failed("The App Store returned an unknown result.")
            }
        } catch { state = .failed(error.localizedDescription) }
    }
}

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
