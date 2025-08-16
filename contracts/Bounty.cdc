import "FungibleToken"
import "DeFiActions"
import "SwapConnectors"
import "NonFungibleToken"

/// Bug Bounty Forum Contract
/// Allows companies to post bug-bounty policies and hackers to submit bug reports
/// Automatically handles token conversion from company deposits to USDF and then to hacker's preferred token
/// Mints NFTs to hackers for each bug report submission
/// Uses DeFiActions SwapSink patterns for proper token conversion
access(all) contract Bounty {
    
    // Events for tracking important actions
    access(all) event CompanyPostCreated(id: UInt64, company: Address, policy: String, bountyAmount: UFix64, tokenType: Type)
    access(all) event HackerPostCreated(id: UInt64, hacker: Address, companyPostId: UInt64, bugDescription: String, tokenPreference: Type, nftId: UInt64)
    access(all) event BugAccepted(postId: UInt64, company: Address, hacker: Address, nftId: UInt64)
    access(all) event BountyPaid(postId: UInt64, hacker: Address, amount: UFix64, tokenType: Type, nftId: UInt64)
    access(all) event TokensConvertedToUSDF(postId: UInt64, fromToken: Type, amount: UFix64, usdfAmount: UFix64)
    access(all) event BugReportNFTMinted(nftId: UInt64, hacker: Address, companyPostId: UInt64, status: String)
    
    // Company post structure containing bug-bounty policy and funds
    access(all) struct CompanyPost {
        access(all) let id: UInt64
        access(all) let company: Address
        access(all) let policy: String
        access(all) let bountyAmount: UFix64
        access(all) let originalTokenType: Type
        access(all) let usdfAmount: UFix64
        access(all) let createdAt: UFix64
        access(all) var isActive: Bool
        
        init(id: UInt64, company: Address, policy: String, bountyAmount: UFix64, originalTokenType: Type, usdfAmount: UFix64) {
            self.id = id
            self.company = company
            self.policy = policy
            self.bountyAmount = bountyAmount
            self.originalTokenType = originalTokenType
            self.usdfAmount = usdfAmount
            self.createdAt = getCurrentBlock().timestamp
            self.isActive = true
        }
    }
    
    // Hacker post structure for bug submissions
    access(all) struct HackerPost {
        access(all) let id: UInt64
        access(all) let hacker: Address
        access(all) let companyPostId: UInt64
        access(all) let bugDescription: String
        access(all) let tokenPreference: Type
        access(all) let createdAt: UFix64
        access(all) var isAccepted: Bool
        access(all) var isPaid: Bool
        access(all) let nftId: UInt64
        
        init(id: UInt64, hacker: Address, companyPostId: UInt64, bugDescription: String, tokenPreference: Type, nftId: UInt64) {
            self.id = id
            self.hacker = hacker
            self.companyPostId = companyPostId
            self.bugDescription = bugDescription
            self.tokenPreference = tokenPreference
            self.createdAt = getCurrentBlock().timestamp
            self.isAccepted = false
            self.isPaid = false
            self.nftId = nftId
        }
    }
    
    // Bug Report NFT structure
    access(all) struct BugReportNFT: NonFungibleToken.INFT {
        access(all) let id: UInt64
        access(all) let hacker: Address
        access(all) let companyPostId: UInt64
        access(all) let bugDescription: String
        access(all) let tokenPreference: Type
        access(all) let createdAt: UFix64
        access(all) var status: String
        access(all) var acceptedAt: UFix64?
        access(all) var paidAt: UFix64?
        access(all) var bountyAmount: UFix64?
        access(all) var company: Address?
        
        init(id: UInt64, hacker: Address, companyPostId: UInt64, bugDescription: String, tokenPreference: Type) {
            self.id = id
            self.hacker = hacker
            self.companyPostId = companyPostId
            self.bugDescription = bugDescription
            self.tokenPreference = tokenPreference
            self.createdAt = getCurrentBlock().timestamp
            self.status = "Submitted"
            self.acceptedAt = nil
            self.paidAt = nil
            self.bountyAmount = nil
            self.company = nil
        }
        
        // Update NFT status when bug is accepted
        access(all) fun updateStatus(newStatus: String, company: Address, bountyAmount: UFix64) {
            self.status = newStatus
            self.acceptedAt = getCurrentBlock().timestamp
            self.company = company
            self.bountyAmount = bountyAmount
        }
        
        // Update NFT status when bounty is paid
        access(all) fun markAsPaid() {
            self.status = "Paid"
            self.paidAt = getCurrentBlock().timestamp
        }
        
        // Get NFT metadata for display
        access(all) fun getMetadata(): {String: String} {
            return {
                "id": self.id.toString(),
                "hacker": self.hacker.toString(),
                "companyPostId": self.companyPostId.toString(),
                "status": self.status,
                "createdAt": self.createdAt.toString(),
                "acceptedAt": self.acceptedAt?.toString() ?? "N/A",
                "paidAt": self.paidAt?.toString() ?? "N/A",
                "bountyAmount": self.bountyAmount?.toString() ?? "N/A",
                "company": self.company?.toString() ?? "N/A"
            }
        }
    }
    
    // NFT Collection for storing bug report NFTs
    access(all) struct BugReportNFTCollection: NonFungibleToken.Provider, NonFungibleToken.Receiver, NonFungibleToken.CollectionPublic, NonFungibleToken.CollectionDisplay {
        access(all) var ownedNFTs: @{UInt64: NonFungibleToken.NFT}
        access(all) var ownedNFTIDs: Set<UInt64>
        
        init() {
            self.ownedNFTs = {}
            self.ownedNFTIDs = Set<UInt64>()
        }
        
        // Required by NonFungibleToken.Provider
        access(all) fun withdraw(withdrawID: UInt64): @NonFungibleToken.NFT {
            let nft <- self.ownedNFTs.remove(key: withdrawID)
                ?? panic("NFT does not exist in this collection")
            self.ownedNFTIDs.remove(withdrawID)
            return <-nft
        }
        
        // Required by NonFungibleToken.Receiver
        access(all) fun deposit(token: @NonFungibleToken.NFT) {
            let tokenID = token.id
            self.ownedNFTs[tokenID] = token
            self.ownedNFTIDs.insert(tokenID)
        }
        
        // Required by NonFungibleToken.CollectionPublic
        access(all) fun borrowNFT(id: UInt64): &NonFungibleToken.NFT? {
            return &self.ownedNFTs[id] as &NonFungibleToken.NFT?
        }
        
        // Required by NonFungibleToken.CollectionDisplay
        access(all) fun display(): {String: String} {
            return {
                "name": "Bug Report NFT Collection",
                "description": "Collection of bug report NFTs from the Bug Bounty Forum",
                "thumbnail": "https://example.com/bug-bounty-icon.png"
            }
        }
        
        // Get all NFT IDs owned by this collection
        access(all) fun getIDs(): [UInt64] {
            return self.ownedNFTIDs.values
        }
        
        // Get NFT by ID
        access(all) fun getNFT(id: UInt64): &BugReportNFT? {
            return &self.ownedNFTs[id] as &BugReportNFT?
        }
        
        // Get all NFTs in the collection
        access(all) fun getAllNFTs(): [&BugReportNFT] {
            var nfts: [&BugReportNFT] = []
            for id in self.ownedNFTIDs.values {
                if let nft = self.getNFT(id: id) {
                    nfts.append(nft)
                }
            }
            return nfts
        }
    }
    
    // Storage paths
    access(all) let CompanyPostStoragePath: StoragePath
    access(all) let HackerPostStoragePath: StoragePath
    access(all) let CompanyVaultStoragePath: StoragePath
    access(all) let USDFVaultStoragePath: StoragePath
    access(all) let NFTCollectionStoragePath: StoragePath
    access(all) let NFTCollectionPublicPath: PublicPath
    
    // Capability paths
    access(all) let CompanyPostCapabilityPath: CapabilityPath
    access(all) let HackerPostCapabilityPath: CapabilityPath
    access(all) let CompanyVaultCapabilityPath: CapabilityPath
    access(all) let USDFVaultCapabilityPath: CapabilityPath
    access(all) let NFTCollectionCapabilityPath: CapabilityPath
    
    // State variables
    access(all) var nextCompanyPostId: UInt64
    access(all) var nextHackerPostId: UInt64
    access(all) var nextNFTId: UInt64
    access(all) var companyPosts: @{UInt64: CompanyPost}
    access(all) var hackerPosts: @{UInt64: HackerPost}
    
    // USDF token type for stable value storage
    access(all) let USDFTokenType: Type
    
    // DeFiActions connector for token conversion
    access(all) var swapConnector: SwapConnectors.Swapper?
    
    init(usdfTokenType: Type) {
        self.CompanyPostStoragePath = /storage/BountyCompanyPosts
        self.HackerPostStoragePath = /storage/BountyHackerPosts
        self.CompanyVaultStoragePath = /storage/BountyCompanyVaults
        self.USDFVaultStoragePath = /storage/BountyUSDFVault
        self.NFTCollectionStoragePath = /storage/BugReportNFTCollection
        self.NFTCollectionPublicPath = /public/BugReportNFTCollection
        
        self.CompanyPostCapabilityPath = /public/BountyCompanyPosts
        self.HackerPostCapabilityPath = /public/BountyHackerPosts
        self.CompanyVaultCapabilityPath = /public/BountyCompanyVaults
        self.USDFVaultCapabilityPath = /public/BountyUSDFVault
        self.NFTCollectionCapabilityPath = /public/BugReportNFTCollection
        
        self.nextCompanyPostId = 1
        self.nextHackerPostId = 1
        self.nextNFTId = 1
        self.companyPosts = {}
        self.hackerPosts = {}
        self.USDFTokenType = usdfTokenType
        self.swapConnector = nil
    }
    
    /// Set the swap connector for token conversion
    access(all) fun setSwapConnector(connector: SwapConnectors.Swapper) {
        self.swapConnector = connector
    }
    
    /// Create a new company post with bug-bounty policy
    /// Company deposits tokens which are automatically converted to USDF for stable value storage
    /// Uses SwapSink pattern for proper DeFiActions integration
    access(all) fun createCompanyPost(
        policy: String,
        bountyAmount: UFix64,
        tokenVault: &{FungibleToken.Vault}
    ): UInt64 {
        pre {
            bountyAmount > 0.0: "Bounty amount must be greater than 0"
            tokenVault.balance >= bountyAmount: "Insufficient tokens for bounty"
            self.swapConnector != nil: "Swap connector not set"
        }
        
        let company = getCurrentAuthAccount().address
        let postId = self.nextCompanyPostId
        self.nextCompanyPostId = postId + 1
        
        let originalTokenType = tokenVault.getType()
        let swapConnector = self.swapConnector!
        
        // Verify the swap connector can handle the conversion
        pre {
            swapConnector.inType() == originalTokenType: "Swap connector cannot handle input token type"
            swapConnector.outType() == self.USDFTokenType: "Swap connector must output USDF"
        }
        
        // Get quote for conversion to USDF
        let quote = swapConnector.quoteIn(forDesired: bountyAmount, reverse: false)
        let usdfAmount = quote.inAmount
        
        // Create company post
        let companyPost = CompanyPost(
            id: postId,
            company: company,
            policy: policy,
            bountyAmount: bountyAmount,
            originalTokenType: originalTokenType,
            usdfAmount: usdfAmount
        )
        
        self.companyPosts[postId] = companyPost
        
        // Create company vault for this post
        let companyVault = CompanyVault(
            postId: postId,
            company: company,
            tokenType: self.USDFTokenType
        )
        
        // Store company vault
        let companyVaultPath = self.CompanyVaultStoragePath.concat(postId.toString())
        getCurrentAuthAccount().storage.save(companyVault, to: companyVaultPath)
        
        // Issue capability for company vault
        getCurrentAuthAccount().capabilities.storage.issue<&CompanyVault>(companyVaultPath)
        
        // Create a unique identifier for this operation
        let operationID = DeFiActions.createUniqueIdentifier()
        
        // Create SwapSink to convert tokens to USDF and deposit into company vault
        let swapSink = SwapConnectors.SwapSink(
            swapper: swapConnector,
            sink: companyVault,
            uniqueID: operationID
        )
        
        // Use SwapSink pattern: withdraw from source and deposit into sink
        // The sink will automatically handle the swap and deposit
        let payment <- tokenVault.withdraw(amount: quote.inAmount)
        swapSink.depositCapacity(from: <-payment)
        
        // Issue capability for company vault
        getCurrentAuthAccount().capabilities.storage.issue<&CompanyVault>(companyVaultPath)
        
        emit CompanyPostCreated(
            id: postId,
            company: company,
            policy: policy,
            bountyAmount: bountyAmount,
            tokenType: originalTokenType
        )
        
        emit TokensConvertedToUSDF(
            postId: postId,
            fromToken: originalTokenType,
            amount: bountyAmount,
            usdfAmount: usdfAmount
        )
        
        return postId
    }
    
    /// Create a new hacker post for bug submission and mint NFT
    access(all) fun createHackerPost(
        companyPostId: UInt64,
        bugDescription: String,
        tokenPreference: Type
    ): UInt64 {
        pre {
            self.companyPosts[companyPostId] != nil: "Company post not found"
            self.companyPosts[companyPostId]!.isActive: "Company post is not active"
            bugDescription.length > 0: "Bug description cannot be empty"
        }
        
        let hacker = getCurrentAuthAccount().address
        let postId = self.nextHackerPostId
        self.nextHackerPostId = postId + 1
        
        let nftId = self.nextNFTId
        self.nextNFTId = nftId + 1
        
        // Create hacker post
        let hackerPost = HackerPost(
            id: postId,
            hacker: hacker,
            companyPostId: companyPostId,
            bugDescription: bugDescription,
            tokenPreference: tokenPreference,
            nftId: nftId
        )
        
        self.hackerPosts[postId] = hackerPost
        
        // Create and mint the NFT
        let nft = BugReportNFT(
            id: nftId,
            hacker: hacker,
            companyPostId: companyPostId,
            bugDescription: bugDescription,
            tokenPreference: tokenPreference
        )
        
        // Get or create NFT collection for the hacker
        let collection = self.getOrCreateNFTCollection(account: getCurrentAuthAccount())
        
        // Mint the NFT to the hacker's collection
        collection.deposit(token: <-nft)
        
        // Store hacker post
        let hackerPostPath = self.HackerPostStoragePath.concat(postId.toString())
        getCurrentAuthAccount().storage.save(hackerPost, to: hackerPostPath)
        
        // Issue capability for hacker post
        getCurrentAuthAccount().capabilities.storage.issue<&HackerPost>(hackerPostPath)
        
        emit HackerPostCreated(
            id: postId,
            hacker: hacker,
            companyPostId: companyPostId,
            bugDescription: bugDescription,
            tokenPreference: tokenPreference,
            nftId: nftId
        )
        
        emit BugReportNFTMinted(
            nftId: nftId,
            hacker: hacker,
            companyPostId: companyPostId,
            status: "Submitted"
        )
        
        return postId
    }
    
    /// Get or create NFT collection for an account
    access(all) fun getOrCreateNFTCollection(account: auth(BorrowValue, SaveValue, IssueStorageCapabilityController) &Account): &BugReportNFTCollection {
        let collectionPath = self.NFTCollectionStoragePath
        let publicPath = self.NFTCollectionPublicPath
        
        // Check if collection already exists
        if let collection = account.storage.borrow<&BugReportNFTCollection>(from: collectionPath) {
            return collection
        }
        
        // Create new collection
        let collection = BugReportNFTCollection()
        account.storage.save(collection, to: collectionPath)
        
        // Issue public capability
        account.capabilities.storage.issue<&{NonFungibleToken.CollectionPublic, NonFungibleToken.CollectionDisplay}>(publicPath)
        
        return account.storage.borrow<&BugReportNFTCollection>(from: collectionPath)!
    }
    
    /// Accept a bug report (only company can do this)
    access(all) fun acceptBug(hackerPostId: UInt64) {
        pre {
            self.hackerPosts[hackerPostId] != nil: "Hacker post not found"
            !self.hackerPosts[hackerPostId]!.isAccepted: "Bug already accepted"
            !self.hackerPosts[hackerPostId]!.isPaid: "Bug already paid"
        }
        
        let hackerPost = self.hackerPosts[hackerPostId]!
        let companyPost = self.companyPosts[hackerPost.companyPostId]!
        let company = getCurrentAuthAccount().address
        
        pre {
            company == companyPost.company: "Only the company can accept bugs"
        }
        
        // Mark bug as accepted
        self.hackerPosts[hackerPostId]!.isAccepted = true
        
        // Update NFT status
        let hackerAccount = getAccount(hackerPost.hacker)
        let collection = hackerAccount.capabilities.storage
            .borrow<&BugReportNFTCollection>(self.NFTCollectionPublicPath)
            ?? panic("NFT collection not found")
        
        if let nft = collection.getNFT(id: hackerPost.nftId) {
            nft.updateStatus(
                newStatus: "Accepted",
                company: company,
                bountyAmount: companyPost.usdfAmount
            )
        }
        
        emit BugAccepted(
            postId: hackerPostId,
            company: company,
            hacker: hackerPost.hacker,
            nftId: hackerPost.nftId
        )
    }
    
    /// Pay out bounty to hacker (only company can do this)
    /// Automatically converts USDF to hacker's preferred token using DeFiActions SwapSink
    access(all) fun payBounty(hackerPostId: UInt64) {
        pre {
            self.hackerPosts[hackerPostId] != nil: "Hacker post not found"
            self.hackerPosts[hackerPostId]!.isAccepted: "Bug must be accepted before payout"
            !self.hackerPosts[hackerPostId]!.isPaid: "Bug already paid"
            self.swapConnector != nil: "Swap connector not set"
        }
        
        let hackerPost = self.hackerPosts[hackerPostId]!
        let companyPost = self.companyPosts[hackerPost.companyPostId]!
        let company = getCurrentAuthAccount().address
        
        pre {
            company == companyPost.company: "Only the company can pay bounties"
        }
        
        // Get company vault
        let companyVaultPath = self.CompanyVaultStoragePath.concat(companyPost.id.toString())
        let companyVaultCap = getCurrentAuthAccount().capabilities.storage
            .borrow<&CompanyVault>(companyVaultPath)
            ?? panic("Company vault capability not found")
        
        // Get hacker account for deposit
        let hackerAccount = getAccount(hackerPost.hacker)
        
        // If hacker prefers USDF, pay directly
        if hackerPost.tokenPreference == self.USDFTokenType {
            let payment <- companyVaultCap.withdraw(amount: companyPost.usdfAmount)
            
            // Try to deposit into hacker's USDF vault
            let hackerVaultCap = hackerAccount.capabilities.storage
                .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                ?? panic("Hacker vault capability not found")
            
            hackerVaultCap.deposit(from: <-payment)
            
            emit BountyPaid(
                postId: hackerPostId,
                hacker: hackerPost.hacker,
                amount: companyPost.usdfAmount,
                tokenType: self.USDFTokenType,
                nftId: hackerPost.nftId
            )
        } else {
            // Convert from USDF to hacker's preferred token using DeFiActions SwapSink
            let swapConnector = self.swapConnector!
            
            // Verify the swap connector can handle the conversion
            pre {
                swapConnector.inType() == self.USDFTokenType: "Swap connector must accept USDF as input"
                swapConnector.outType() == hackerPost.tokenPreference: "Swap connector must output hacker's preferred token"
            }
            
            // Create a unique identifier for this operation
            let operationID = DeFiActions.createUniqueIdentifier()
            
            // Create a temporary vault to hold the hacker's preferred token
            let tempVault = TempVault(tokenType: hackerPost.tokenPreference)
            
            // Create SwapSink to convert USDF to hacker's preferred token
            let swapSink = SwapConnectors.SwapSink(
                swapper: swapConnector,
                sink: tempVault,
                uniqueID: operationID
            )
            
            // Withdraw USDF from company vault and deposit into swap sink
            let usdfPayment <- companyVaultCap.withdraw(amount: companyPost.usdfAmount)
            swapSink.depositCapacity(from: <-usdfPayment)
            
            // Get the converted tokens from temp vault
            let convertedTokens <- tempVault.withdrawAll()
            
            // Deposit into hacker's vault
            let hackerVaultCap = hackerAccount.capabilities.storage
                .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                ?? panic("Hacker vault capability not found")
            
            hackerVaultCap.deposit(from: <-convertedTokens)
            
            emit BountyPaid(
                postId: hackerPostId,
                hacker: hackerPost.hacker,
                amount: companyPost.usdfAmount,
                tokenType: hackerPost.tokenPreference,
                nftId: hackerPost.nftId
            )
        }
        
        // Mark as paid
        self.hackerPosts[hackerPostId]!.isPaid = true
        
        // Update NFT status
        let collection = hackerAccount.capabilities.storage
            .borrow<&BugReportNFTCollection>(self.NFTCollectionPublicPath)
            ?? panic("NFT collection not found")
        
        if let nft = collection.getNFT(id: hackerPost.nftId) {
            nft.markAsPaid()
        }
        
        // Deactivate company post if bounty is paid
        self.companyPosts[companyPost.id]!.isActive = false
    }
    
    /// Get company post by ID
    access(all) fun getCompanyPost(id: UInt64): CompanyPost? {
        return self.companyPosts[id]
    }
    
    /// Get hacker post by ID
    access(all) fun getHackerPost(id: UInt64): HackerPost? {
        return self.hackerPosts[id]
    }
    
    /// Get all company posts
    access(all) fun getAllCompanyPosts(): [CompanyPost] {
        return self.companyPosts.values
    }
    
    /// Get all hacker posts
    access(all) fun getAllHackerPosts(): [HackerPost] {
        return self.hackerPosts.values
    }
    
    /// Get hacker posts for a specific company post
    access(all) fun getHackerPostsForCompany(companyPostId: UInt64): [HackerPost] {
        return self.hackerPosts.values.filter { post in
            post.companyPostId == companyPostId
        }
    }
    
    /// Get pending hacker posts for a company (accepted but not paid)
    access(all) fun getPendingHackerPosts(companyPostId: UInt64): [HackerPost] {
        return self.hackerPosts.values.filter { post in
            post.companyPostId == companyPostId && post.isAccepted && !post.isPaid
        }
    }
    
    /// Get NFT collection for an account
    access(all) fun getNFTCollection(account: PublicAccount): &BugReportNFTCollection? {
        return account.capabilities.storage
            .borrow<&BugReportNFTCollection>(self.NFTCollectionPublicPath)
    }
    
    /// Get all NFTs for a hacker
    access(all) fun getHackerNFTs(hackerAddress: Address): [&BugReportNFT] {
        let account = getAccount(hackerAddress)
        let collection = account.capabilities.storage
            .borrow<&BugReportNFTCollection>(self.NFTCollectionPublicPath)
        
        if collection == nil {
            return []
        }
        
        return collection!.getAllNFTs()
    }
    
    /// Get NFT by ID
    access(all) fun getNFT(nftId: UInt64): &BugReportNFT? {
        // This would need to be implemented with a mapping or by searching through all collections
        // For now, return nil - in practice you'd want an index
        return nil
    }
}

/// Company vault for storing USDF bounty funds
access(all) struct CompanyVault {
    access(all) let postId: UInt64
    access(all) let company: Address
    access(all) let tokenType: Type
    access(all) var balance: UFix64
    
    init(postId: UInt64, company: Address, tokenType: Type) {
        self.postId = postId
        self.company = company
        self.tokenType = tokenType
        self.balance = 0.0
    }
    
    /// Deposit tokens into vault
    access(all) fun deposit(from: @{FungibleToken.Vault}) {
        pre {
            from.getType() == self.tokenType: "Token type mismatch"
        }
        
        let amount = from.balance
        if amount > 0.0 {
            let payment <- from.withdraw(amount: amount)
            self.balance = self.balance + amount
            destroy payment
        }
    }
    
    /// Withdraw tokens from vault (only company can do this)
    access(all) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
        pre {
            amount > 0.0: "Withdrawal amount must be greater than 0"
            amount <= self.balance: "Insufficient balance"
        }
        
        self.balance = self.balance - amount
        
        // Create a new vault with the withdrawn amount
        // In practice, this would use the actual token contract's createEmptyVault function
        return createEmptyVault()
    }
    
    /// Helper function to create empty vault (placeholder)
    access(all) fun createEmptyVault(): @{FungibleToken.Vault} {
        // This is a placeholder - in practice, you would call the actual token contract
        // to create an empty vault of the correct type
        panic("createEmptyVault not implemented - use actual token contract")
    }
}

/// Temporary vault for holding converted tokens during swap operations
/// Implements DeFiActions.Sink interface for use with SwapSink
access(all) struct TempVault: DeFiActions.Sink {
    access(all) let tokenType: Type
    access(all) var balance: UFix64
    access(all) var uniqueID: DeFiActions.UniqueIdentifier?
    
    init(tokenType: Type) {
        self.tokenType = tokenType
        self.balance = 0.0
        self.uniqueID = nil
    }
    
    // Required by DeFiActions.Sink
    access(all) fun getSinkType(): Type {
        return self.tokenType
    }
    
    // Required by DeFiActions.Sink
    access(all) fun minimumCapacity(): UFix64 {
        return UFix64.max
    }
    
    // Required by DeFiActions.Sink
    access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
        pre {
            from.getType() == self.tokenType: "Token type mismatch"
        }
        
        let amount = from.balance
        if amount > 0.0 {
            let payment <- from.withdraw(amount: amount)
            self.balance = self.balance + amount
            destroy payment
        }
    }
    
    // Withdraw all tokens from temp vault
    access(all) fun withdrawAll(): @{FungibleToken.Vault} {
        let amount = self.balance
        self.balance = 0.0
        
        // Create a new vault with the withdrawn amount
        // In practice, this would use the actual token contract's createEmptyVault function
        return createEmptyVault()
    }
    
    // Required by DeFiActions.Sink
    access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
        return DeFiActions.ComponentInfo(
            type: self.getType(),
            id: self.id(),
            innerComponents: []
        )
    }
    
    // Implementation detail for UniqueIdentifier passthrough
    access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
        return self.uniqueID
    }
    
    // Allow the framework to set/propagate a UniqueIdentifier for tracing
    access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
        self.uniqueID = id
    }
}
