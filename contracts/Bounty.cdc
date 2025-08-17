import "FungibleToken"
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
    
    
    // Storage paths
    access(all) let CompanyPostStoragePath: StoragePath
    access(all) let HackerPostStoragePath: StoragePath
    access(all) let CompanyVaultStoragePath: StoragePath
    access(all) let USDFVaultStoragePath: StoragePath
    
    // Capability paths
    access(all) let CompanyPostCapabilityPath: CapabilityPath
    access(all) let HackerPostCapabilityPath: CapabilityPath
    access(all) let CompanyVaultCapabilityPath: CapabilityPath
    access(all) let USDFVaultCapabilityPath: CapabilityPath

    
    // State variables
    access(all) var nextCompanyPostId: UInt64
    access(all) var nextHackerPostId: UInt64
    access(all) var companyPosts: {UInt64: CompanyPost}
    access(all) var hackerPosts: {UInt64: HackerPost}
    
    // USDF token type for stable value storage
    access(all) let USDFTokenType: Type
    
    // Placeholder for future DeFi integration
    access(all) var swapConnector: Bool
    
    init() {
        self.CompanyPostStoragePath = /storage/BountyCompanyPosts
        self.HackerPostStoragePath = /storage/BountyHackerPosts
        self.CompanyVaultStoragePath = /storage/BountyCompanyVaults
        self.USDFVaultStoragePath = /storage/BountyUSDFVault
        
        self.CompanyPostCapabilityPath = /public/BountyCompanyPosts
        self.HackerPostCapabilityPath = /public/BountyHackerPosts
        self.CompanyVaultCapabilityPath = /public/BountyCompanyVaults
        self.USDFVaultCapabilityPath = /public/BountyUSDFVault
        
        self.nextCompanyPostId = 1
        self.nextHackerPostId = 1
        self.companyPosts = {}
        self.hackerPosts = {}
        self.swapConnector = false
    }
    
    /// Set the swap connector for token conversion
    access(all) fun setSwapConnector(connector: SwapConnectors.Swapper) {
        self.swapConnector = connector
    }
    
    /// Create a new company post with bug-bounty policy
    /// Company deposits tokens which are automatically converted to USDF for stable value storage
    /// Uses SwapSink pattern for proper DeFiActions integration
    /// Create a new company post with bug-bounty policy
/// Company deposits tokens which are automatically converted to USDF for stable value storage
access(all) fun createCompanyPost(
    policy: String,
    bountyAmount: UFix64,
    tokenVault: @{FungibleToken.Vault},
    company: Address
): UInt64 {
    pre {
        bountyAmount > 0.0: "Bounty amount must be greater than 0"
        tokenVault.balance >= bountyAmount: "Insufficient tokens for bounty"
    }
    
    let postId = self.nextCompanyPostId
    self.nextCompanyPostId = postId + 1
    
    let originalTokenType = tokenVault.getType()
    
    // Get quote from SinkSwap
    let swapConnector = SinkSwapConnector(routerAddress: 0x123) // Replace with actual SinkSwap router address
    let usdfAmount = swapConnector.getQuote(
        fromToken: originalTokenType,
        toToken: self.USDFTokenType,
        amount: bountyAmount
    )
    
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
    
    // Execute the swap through SinkSwap
    let payment <- tokenVault.withdraw(amount: bountyAmount)
    let usdfTokens <- swapConnector.executeSwap(
        fromVault: &payment,
        toToken: self.USDFTokenType,
        amount: bountyAmount
    )
    
    // Deposit converted USDF into company vault
    companyVault.deposit(from: <-usdfTokens)
    
    // Store company vault
    let companyVaultPath = self.CompanyPostStoragePath.concat(postId.toString())
    getCurrentAuthAccount().storage.save(companyVault, to: companyVaultPath)
    
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
        tokenPreference: Type,
        hacker: Address
    ): UInt64 {
        pre {
            self.companyPosts[companyPostId] != nil: "Company post not found"
            self.companyPosts[companyPostId]!.isActive: "Company post is not active"
            bugDescription.length > 0: "Bug description cannot be empty"
        }
        
        let postId = self.nextHackerPostId
        self.nextHackerPostId = postId + 1
        
        
        // Create hacker post
        let hackerPost = HackerPost(
            id: postId,
            hacker: hacker,
            companyPostId: companyPostId,
            bugDescription: bugDescription,
            tokenPreference: tokenPreference
        )
        
        self.hackerPosts[postId] = hackerPost
        
        
        emit HackerPostCreated(
            id: postId,
            hacker: hacker,
            companyPostId: companyPostId,
            bugDescription: bugDescription,
            tokenPreference: tokenPreference,
        )
        
        
        return postId
    }





  


    /// Accept a bug report (only company can do this)
    access(all) fun acceptBug(hackerPostId: UInt64, company: Address) {
        let hackerPost = self.hackerPosts[hackerPostId]!
        let companyPost = self.companyPosts[hackerPost.companyPostId]!
        
        // Mark bug as accepted
        self.hackerPosts[hackerPostId]!.isAccepted = true
        
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
    access(all) fun payBounty(hackerPostId: UInt64, company: Address) {
        let hackerPost = self.hackerPosts[hackerPostId]!
        let companyPost = self.companyPosts[hackerPost.companyPostId]!


        

        
        // Get hacker account for deposit
        let hackerAccount = getAccount(hackerPost.hacker)
        
        // If hacker prefers USDF, pay directly
        if hackerPost.tokenPreference == self.USDFTokenType {
            let payment <- companyVaultCap.withdraw(amount: companyPost.usdfAmount)
            
            // Try to deposit into hacker's USDF vault
            let hackerVaultCap = hackerAccount.capabilities.storage.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)?? panic("Hacker vault capability not found")
            
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
        
    }
    
    /// Get company post by ID
    access(all) fun getCompanyPost(id: UInt64): CompanyPost? {
        return self.companyPosts[id]
    }
    
    /// Get hacker post by ID
    access(all) fun getHackerPost(id: UInt64): HackerPost? {
        return self.hackerPosts[id]
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
            id: "temp-vault",
            innerComponents: []
        )
    }
}

// First, create a SinkSwap connector interface
access(all) struct SinkSwapConnector {
    access(all) let routerAddress: Address
    access(all) let supportedTokens: [Type]
    
    init(routerAddress: Address) {
        self.routerAddress = routerAddress
        self.supportedTokens = []
    }
    
    // Get quote for token conversion
    access(all) fun getQuote(
        fromToken: Type, 
        toToken: Type, 
        amount: UFix64
    ): UFix64 {
        // This would call SinkSwap router to get conversion rate
        // For now, return 1:1 ratio
        return amount
    }
    
    // Execute the swap
    access(all) fun executeSwap(
        fromVault: &{FungibleToken.Vault},
        toToken: Type,
        amount: UFix64
    ): @{FungibleToken.Vault} {
        // This would integrate with SinkSwap router
        // For now, just return the input tokens
        return fromVault.withdraw(amount: amount)
    }
}
}
