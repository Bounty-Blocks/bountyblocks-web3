import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "SwapConnectors"

/// Bug Bounty Forum Contract
/// - Companies stake in ANY token, it's swapped to FlowToken and stored in a contract-owned pool
/// - Bounties are paid out from FlowToken to the hacker's token of choice
access(all) contract Bounty {

    // -------------------- Events --------------------
    access(all) event CompanyPostCreated(
        id: UInt64,
        company: Address,
        policy: String,
        inToken: Type,
        flowTokenCredited: UFix64
    )
    access(all) event HackerPostCreated(
        id: UInt64,
        hacker: Address,
        companyPostId: UInt64,
        tokenPreference: Type,
        isAccepted: Bool,
        isPaid: Bool
    )
    access(all) event BugAccepted(
        postId: UInt64,
        company: Address,
        hacker: Address
    )
    access(all) event BountyPaid(
        postId: UInt64,
        hacker: Address,
        amount: UFix64,
        paidToken: Type
    )
    access(all) event TokensConvertedToFlowToken(
        postId: UInt64,
        fromToken: Type,
        flowTokenAmount: UFix64
    )

    // -------------------- Data --------------------
    access(all) struct CompanyPost {
        access(all) let id: UInt64
        access(all) let company: Address
        access(all) let policy: String
        access(all) let originalTokenType: Type
        access(all) var isActive: Bool

        init(id: UInt64, company: Address, policy: String, originalTokenType: Type) {
            self.id = id
            self.company = company
            self.policy = policy
            self.originalTokenType = originalTokenType
            self.isActive = true
        }
    }

    access(all) struct HackerPost {
        access(all) let id: UInt64
        access(all) let hacker: Address
        access(all) let companyPostId: UInt64
        access(all) let tokenPreference: Type
        access(all) var isAccepted: Bool
        access(all) var isPaid: Bool

        init(id: UInt64, hacker: Address, companyPostId: UInt64, tokenPreference: Type) {
            self.id = id
            self.hacker = hacker
            self.companyPostId = companyPostId
            self.tokenPreference = tokenPreference
            self.isAccepted = false
            self.isPaid = false
        }

        // Add setter functions
        access(all) fun setAccepted(accepted: Bool) { self.isAccepted = accepted }
        access(all) fun setPaid(paid: Bool) { self.isPaid = paid }
    }

    // -------------------- State --------------------
    access(contract) var globalFlowToken: @FlowToken.Vault
    access(all) let FlowTokenType: Type

    access(all) var nextCompanyPostId: UInt64
    access(all) var nextHackerPostId: UInt64
    access(all) var companyPosts: {UInt64: CompanyPost}
    access(all) var hackerPosts: {UInt64: HackerPost}

    // Per company-post FlowToken accounting (how much of the pool belongs to this post)
    access(all) var postFlowToken: {UInt64: UFix64}

    // -------------------- Init/Destroy --------------------
    init() {
        self.globalFlowToken <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        self.FlowTokenType = Type<@FlowToken.Vault>()

        self.nextCompanyPostId = 1
        self.nextHackerPostId = 1
        self.companyPosts = {}
        self.hackerPosts = {}
        self.postFlowToken = {}
    }

// -------------------- Action Interfaces --------------------
access(all) struct ActionSink {
    access(all) fun getSinkType(): Type { return Type<@FlowToken.Vault>() }
    access(all) fun minimumCapacity(): UFix64 { return 99999999999.0 }

    access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
        if from.getType() != Type<@FlowToken.Vault>() || from.balance == 0.0 { return }
        let moved <- from.withdraw(amount: from.balance)
        // Use the enclosing contract directly
        Bounty.globalFlowToken.deposit(from: <-moved)
    }
}

access(all) struct ActionSource {
    access(all) fun getSourceType(): Type { return Type<@FlowToken.Vault>() }
    access(all) fun minimumAvailable(): UFix64 { return Bounty.globalFlowToken.balance }

    // Keep this restricted so outsiders can’t drain your vault
    access(FungibleToken.Withdraw)
    fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
        if maxAmount == 0.0 || Bounty.globalFlowToken.balance == 0.0 {
            return <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        }
        let take = maxAmount < Bounty.globalFlowToken.balance
            ? maxAmount
            : Bounty.globalFlowToken.balance
        return <- Bounty.globalFlowToken.withdraw(amount: take)
    }
}

// Constructors no longer need &self
access(all) fun makeActionSink(): ActionSink { return ActionSink() }
access(all) fun makeActionSource(): ActionSource { return ActionSource() }

    access(all) fun flowTokenPoolBalance(): UFix64 { return self.globalFlowToken.balance }

    // Add SinkSwap connector interface
    access(all) struct SinkSwapConnector {
    access(all) let routerAddress: Address
    access(all) let supportedTokens: [Type]
    
    init(routerAddress: Address) {
        self.routerAddress = routerAddress
        self.supportedTokens = []
    }

    access(all) fun getQuote(fromToken: Type, toToken: Type, amount: UFix64): UFix64 {
        return amount // placeholder 1:1
    }

    // NOTE: take the payment by MOVE, and deposit to a Receiver
    access(all) fun executeSwap(
        payment: @{FungibleToken.Vault},
        to: &{FungibleToken.Receiver}
    ): UFix64 {
        let amount = payment.balance
        to.deposit(from: <-payment)   // consumes the resource
        return amount                  // placeholder: 1:1
    }
}


    // -------------------- Public API --------------------

    /// 1) Company creates a bounty post and stakes ANY token.
    ///    We swap ALL provided tokens -> FlowToken and credit this post's balance.

    access(all) fun createCompanyPost(
        policy: String,
        tokenVault: @{FungibleToken.Vault},
        company: Address,
        sinkSwapConnector: SinkSwapConnector
    ): UInt64 {
        let postId = self.nextCompanyPostId
        self.nextCompanyPostId = postId + 1

        // Create the post record
        let originalType = tokenVault.getType()
        let companyPost = CompanyPost(
            id: postId,
            company: company,
            policy: policy,
            originalTokenType: originalType
        )
        self.companyPosts[postId] = companyPost

        let before = self.flowTokenPoolBalance()

let convertedAmount = sinkSwapConnector.executeSwap(
    payment: <-tokenVault,                                     // MOVE it
    to: &self.globalFlowToken as &{FungibleToken.Receiver}     // just needs Receiver
)

let after = self.flowTokenPoolBalance()
let delta = after - before
self.postFlowToken[postId] = (self.postFlowToken[postId] ?? 0.0) + delta

// remove: destroy tokenVault   // (already consumed by deposit)
emit TokensConvertedToFlowToken(postId: postId, fromToken: originalType, flowTokenAmount: delta)
emit CompanyPostCreated(id: postId, company: company, policy: policy, inToken: originalType, flowTokenCredited: delta)

return postId
    }

    /// 2) Hacker files a submission indicating payout token preference.
    access(all) fun createHackerPost(
        companyPostId: UInt64,
        hacker: Address,
        tokenPreference: Type,
        isAccepted: Bool,
        isPaid: Bool
    ): UInt64 {

        let postId = self.nextHackerPostId
        self.nextHackerPostId = postId + 1

        let hp = HackerPost(
            id: postId,
            hacker: hacker,
            companyPostId: companyPostId,
            tokenPreference: tokenPreference
        )
        self.hackerPosts[postId] = hp

        emit HackerPostCreated(
            id: postId,
            hacker: hacker,
            companyPostId: companyPostId,
            tokenPreference: tokenPreference,
            isAccepted: isAccepted,
            isPaid: isPaid
        )

        return postId
    }

    /// 3) Company accepts the bug (authorization is by parameter — enforce via your tx policy).
    access(all) fun acceptBug(hackerPostId: UInt64, company: Address) {
        let hp = self.hackerPosts[hackerPostId] ?? panic("Hacker post not found")
        let cp = self.companyPosts[hp.companyPostId] ?? panic("Company post not found")

        self.hackerPosts[hackerPostId]!.setAccepted(accepted: true)
        emit BugAccepted(postId: hackerPostId, company: company, hacker: hp.hacker)
    }

    /// 4) Payout bounty from this post's FlowToken to the hacker in their preferred token.
   // Change the signature to:
access(all) fun payBounty(
    hackerPostId: UInt64,
    company: Address,
    amountFlowToken: UFix64,
    sinkSwapConnector: SinkSwapConnector,
    hackerTokenReceiver: &{FungibleToken.Receiver}
) {
    let hp = self.hackerPosts[hackerPostId] ?? panic("Hacker post not found")
    let _cp = self.companyPosts[hp.companyPostId] ?? panic("Company post not found")

    // debit allocation safely
    let cur = self.postFlowToken[hp.companyPostId] ?? 0.0
    if amountFlowToken > cur { panic("insufficient allocated funds for this post") }
    self.postFlowToken[hp.companyPostId] = cur - amountFlowToken

    // MOVE from the pool
    let flowTokenPayment <- self.globalFlowToken.withdraw(amount: amountFlowToken)

    // swap consumes the moved resource and deposits to recipient
    let convertedAmount = sinkSwapConnector.executeSwap(
        payment: <-flowTokenPayment,
        to: hackerTokenReceiver
    )

    self.hackerPosts[hackerPostId]!.setPaid(paid: true)
    emit BountyPaid(
        postId: hackerPostId,
        hacker: hp.hacker,
        amount: convertedAmount,
        paidToken: hp.tokenPreference   // use declared preference
    )
}

    // -------------------- Convenience Views --------------------
    access(all) fun getCompanyPost(id: UInt64): CompanyPost? { return self.companyPosts[id] }
    access(all) fun getHackerPost(id: UInt64): HackerPost? { return self.hackerPosts[id] }
    access(all) fun postBalanceFlowToken(companyPostId: UInt64): UFix64 { return self.postFlowToken[companyPostId] ?? 0.0 }
}
