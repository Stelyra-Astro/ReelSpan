import Foundation
import Combine
import StoreKit

@MainActor
final class TipPurchaseManager: ObservableObject {
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var state: TipState = .unavailable
    private var transactionTasks: [Task<Void, Never>] = []

    init() {
        transactionTasks = [
            Task { [weak self] in await self?.observeUpdates() },
            Task { [weak self] in await self?.observeUnfinishedTransactions() }
        ]
    }

    deinit { transactionTasks.forEach { $0.cancel() } }

    func load() async {
        guard !state.isBusy else { return }
        state = .loading
        do {
            let loadedProducts = try await Product.products(for: TipRules.productIDs)
                .filter { $0.type == .consumable && TipRules.isTipProductID($0.id) }
            products = Dictionary(uniqueKeysWithValues: loadedProducts.map { ($0.id, $0) })
            state = products.isEmpty ? .unavailable : .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func product(for productID: String) -> Product? {
        products[productID]
    }

    func purchase(productID: String) async {
        guard TipRules.isTipProductID(productID), !state.isBusy else { return }
        guard let product = products[productID] else {
            state = .unavailable
            return
        }
        state = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await finishIfTip(transaction)
                case .unverified:
                    state = .unverified
                }
            case .pending:
                state = .pending
            case .userCancelled:
                state = .cancelled
            @unknown default:
                state = .failed("The App Store returned an unknown result.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func observeUpdates() async {
        for await result in Transaction.updates {
            guard !Task.isCancelled else { return }
            await handle(result)
        }
    }

    private func observeUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard !Task.isCancelled else { return }
            await handle(result)
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await finishIfTip(transaction)
        case .unverified(let transaction, _):
            guard TipRules.isTipProductID(transaction.productID) else { return }
            state = .unverified
        }
    }

    private func finishIfTip(_ transaction: Transaction) async {
        guard TipRules.isTipProductID(transaction.productID) else { return }
        await transaction.finish()
        state = .verified
    }
}
