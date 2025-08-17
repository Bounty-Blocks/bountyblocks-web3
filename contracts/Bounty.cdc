import "FungibleToken"
import "DeFiActions"
import "SwapConnectors"

/// Bug Bounty Forum Contract
/// - Companies stake in ANY token, it's swapped to USDF and stored in a contract-owned pool
/// - Bounties are paid out from USDF to the hacker's token of choice
access(all) contract Bounty {

    // -------------------- Events --------------------
    access(all) event CompanyPostCreated(
        id: UInt64,
        company: Address,
        policy: String,
        inToken: Type,
        usdfCredited: UFix64
    )
    access(all) event HackerPostCreated(
        id: UInt64,
        hacker: Address,
        companyPostId: UInt64,
        tokenPreference: Type
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
    access(all) event TokensConvertedToUSDF(
        postId: UInt64,
        fromToken: Type,
        usdfAmount: UFix64
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
    }

    // -------------------- State --------------------
    access(contract) var globalUSDF: @USDF.Vault
    access(all) let USDFTokenType: Type

    access(all) var nextCompanyPostId: UInt64
    access(all) var nextHackerPostId: UInt64
    access(all) var companyPosts: {UInt64: CompanyPost}
    access(all) var hackerPosts: {UInt64: HackerPost}

    // Per company-post USDF accounting (how much of the pool belongs to this post)
    access(all) var postUSDF: {UInt64: UFix64}

    // -------------------- Init/Destroy --------------------
    init() {
        self.globalUSDF <- USDF.createEmptyVault()
        self.USDFTokenType = Type<@USDF.Vault>()

        self.nextCompanyPostId = 1
        self.nextHackerPostId = 1
        self.companyPosts = {}
        self.hackerPosts = {}
        self.postUSDF = {}
    }

    destroy() {
        destroy self.globalUSDF
    }

    // -------------------- Internal Sink/Source on the USDF pool --------------------
    access(contract) struct GlobalUSDFSink: DeFiActions.Sink {
        access(contract) let bounty: &Bounty
        init(bounty: &Bounty) { self.bounty = bounty }
        access(all) view fun getSinkType(): Type { return Type<@USDF.Vault>() }
        access(all) fun minimumCapacity(): UFix64 { return 999_000_000_000.0 }
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if from.getType() != self.getSinkType() || from.balance == 0.0 { return }
            let moved <- from.withdraw(amount: from.balance)
            self.bounty.globalUSDF.deposit(from: <-moved)
        }
    }

    access(contract) struct GlobalUSDFSource: DeFiActions.Source {
        access(contract) let bounty: &Bounty
        init(bounty: &Bounty) { self.bounty = bounty }
        access(all) view fun getSourceType(): Type { return Type<@USDF.Vault>() }
        access(all) fun minimumAvailable(): UFix64 { return self.bounty.globalUSDF.balance }
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if maxAmount == 0.0 || self.bounty.globalUSDF.balance == 0.0 {
                return <- DeFiActionsUtils.getEmptyVault(self.getSourceType())
            }
            let take = maxAmount < self.bounty.globalUSDF.balance ? maxAmount : self.bounty.globalUSDF.balance
            return <- self.bounty.globalUSDF.withdraw(amount: take)
        }
    }

    access(all) fun makeUSDFSink(): DeFiActions.Sink { return GlobalUSDFSink(bounty: &self as &Bounty) }
    access(all) fun makeUSDFSource(): DeFiActions.Source { return GlobalUSDFSource(bounty: &self as &Bounty) }
    access(all) view fun usdfPoolBalance(): UFix64 { return self.globalUSDF.balance }

    // -------------------- Public API --------------------

    /// 1) Company creates a bounty post and stakes ANY token.
    ///    We swap ALL provided tokens -> USDF and credit this post's balance.

    access(all) fun createCompanyPost(
        policy: String,
        tokenVault: @{FungibleToken.Vault},
        company: Address,
        swapperIn: {DeFiActions.Swapper}
    ): UInt64 {
        let postId = self.nextCompanyPostId
        self.nextCompanyPostId = postId + 1

        // Create the post record
        let originalType = tokenVault.getType()
        let post = CompanyPost(
            id: postId,
            company: company,
            policy: policy,
            originalTokenType: originalType
        )
        self.companyPosts[postId] = post

        // Track pool delta to credit exact USDF received
        let before = self.usdfPoolBalance()


        // Swap & deposit to global USDF pool
        let sink = self.makeUSDFSink()
        let swapSink = SwapConnectors.SwapSink(swapper: swapperIn, sink: sink, uniqueID: nil)

        var tmp <- tokenVault
        swapSink.depositCapacity(from: &tmp as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
        destroy tmp

        let after = self.usdfPoolBalance()
        let delta = after - before
        self.postUSDF[postId] = (self.postUSDF[postId] ?? 0.0) + delta

        emit TokensConvertedToUSDF(postId: postId, fromToken: originalType, usdfAmount: delta)
        emit CompanyPostCreated(
            id: postId,
            company: company,
            policy: policy,
            inToken: originalType,
            usdfCredited: delta
        )

        return postId
    }

    /// 2) Hacker files a submission indicating payout token preference.
    access(all) fun createHackerPost(
        companyPostId: UInt64,
        hacker: Address,
        tokenPreference: Type
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
            tokenPreference: tokenPreference
        )

        return postId
    }

    /// 3) Company accepts the bug (authorization is by parameter — enforce via your tx policy).
    access(all) fun acceptBug(hackerPostId: UInt64, company: Address) {
        let hp = self.hackerPosts[hackerPostId] ?? panic("Hacker post not found")
        let cp = self.companyPosts[hp.companyPostId] ?? panic("Company post not found")

        self.hackerPosts[hackerPostId]!.isAccepted = true
        emit BugAccepted(postId: hackerPostId, company: company, hacker: hp.hacker)
    }






    /// 4) Payout bounty from this post's USDF to the hacker in their preferred token.
    access(all) fun payBounty(
        hackerPostId: UInt64,
        company: Address,
        amountUSDF: UFix64,
        usdfToPayout: {DeFiActions.Swapper},
        payoutReceiver: &{FungibleToken.Receiver}
    ) {
        let hp = self.hackerPosts[hackerPostId] ?? panic("Hacker post not found")
        let cp = self.companyPosts[hp.companyPostId] ?? panic("Company post not found")

        // Check and debit the post's USDF allocation
        let cur = self.postUSDF[hp.companyPostId] ?? 0.0
        self.postUSDF[hp.companyPostId] = cur - amountUSDF

        // Pull from pool and convert to hacker's token
        let source = self.makeUSDFSource()
        let swapSource = SwapConnectors.SwapSource(swapper: usdfToPayout, source: source, uniqueID: nil)

        let out <- swapSource.withdrawAvailable(maxAmount: amountUSDF)
        payoutReceiver.deposit(from: <-out)

        self.hackerPosts[hackerPostId]!.isPaid = true
        emit BountyPaid(postId: hackerPostId, hacker: hp.hacker, amount: amountUSDF, paidToken: hp.tokenPreference)
    }



    // -------------------- Convenience Views --------------------
    access(all) view fun getCompanyPost(id: UInt64): CompanyPost? { return self.companyPosts[id] }
    access(all) view fun getHackerPost(id: UInt64): HackerPost? { return self.hackerPosts[id] }
    access(all) view fun postBalanceUSDF(companyPostId: UInt64): UFix64 { return self.postUSDF[companyPostId] ?? 0.0 }
    access(all) fun setPostActive(companyPostId: UInt64, active: Bool) {
        pre { self.companyPosts[companyPostId] != nil: "Company post not found" }
        self.companyPosts[companyPostId]!.isActive = active
    }
}
