import FungibleToken from 0xFUNGIBLETOKEN
import FlowToken from 0xFLOWTOKEN

access(all) contract Bounty {

    // ─────────────────────────────
    // Events (one canonical per action)
    // ─────────────────────────────
    access(all) event CompanyCreated(company: Address, name: String, defaultPerPayout: UFix64)
    // "Sponsor" here is the company itself (owner-funded pool).
    access(all) event SponsorStaked(company: Address, sponsor: Address, amount: UFix64, newPool: UFix64)

    // NOTE: We emit a single event on submission to avoid double-counting in indexers.
    // If you want a separate "ForumPosted", you can emit both (see comment in submitIssue).
    access(all) event IssueSubmitted(company: Address, issueId: UInt64, hacker: Address, summary: String)
    access(all) event IssueAccepted(company: Address, issueId: UInt64, hacker: Address, by: Address)
    access(all) event BountyPaid(company: Address, issueId: UInt64, hacker: Address, amount: UFix64)
    access(all) event CompletionStatusSet(company: Address, issueId: UInt64, hacker: Address, completed: Bool)
    access(all) event CompletionMessage(company: Address, issueId: UInt64, message: String)

    // ─────────────────────────────
    // Data
    // ─────────────────────────────
    access(all) struct CompanyMeta {
        access(all) let company: Address
        access(all) let name: String
        access(all) var defaultPerPayout: UFix64
        init(company: Address, name: String, defaultPerPayout: UFix64) {
            self.company = company
            self.name = name
            self.defaultPerPayout = defaultPerPayout
        }
    }

    // Issue keeps the hacker's typed FlowToken Receiver capability
    access(all) struct Issue {
        access(all) let sponsor: Address
        access(all) let hacker: Address
        access(all) let summary: String
        access(all) var accepted: Bool
        access(all) var completed: Bool
        access(all) var paid: UFix64
        access(all) var notified: Bool
        access(all) let hackerReceiver: Capability<&FlowToken.Vault{FungibleToken.Receiver}>
        init(
            sponsor: Address,
            hacker: Address,
            summary: String,
            hackerReceiver: Capability<&FlowToken.Vault{FungibleToken.Receiver}>
        ) {
            self.sponsor   = sponsor
            self.hacker    = hacker
            self.summary   = summary
            self.accepted  = false
            self.completed = false
            self.paid      = 0.0
            self.notified  = false
            self.hackerReceiver = hackerReceiver
        }
    }

    // ─────────────────────────────
    // Storage (keyed by company)
    // ─────────────────────────────
    access(all) var metaByCompany: {Address: CompanyMeta}
    access(self) var vaultByCompany: @{Address: FlowToken.Vault}           // pooled FLOW per company
    access(all) var stakesByCompany: {Address: {Address: UFix64}}          // company -> sponsor -> amount
    access(self) var nextIssueIdByCompany: {Address: UInt64}               // company -> next issueId
    access(all) var issuesByCompany: {Address: {UInt64: Issue}}            // company -> issueId -> Issue

    // ─────────────────────────────
    // Admin resource (capability proves control)
    // The company saves this under /storage and links a /private capability.
    // Any mutating "owner-only" action requires borrowing this.
    // ─────────────────────────────
    access(all) resource CompanyAdmin {
        // Set on registration; used as the single source of truth for owner-only scopes.
        access(all) var company: Address?

        // Internal helper to resolve the company address or fail with a clear error.
        access(self) fun mustCompany(): Address {
            let c = self.company
            if c == nil { panic("admin not registered with a company yet") }
            return c!
        }

        // Owner funds the company pool with FlowToken.
        access(all) fun sponsorStake(payment: @FlowToken.Vault) {
            pre { payment.balance > 0.0: "stake must be > 0" }
            let company = self.mustCompany()
            Bounty.vaultByCompany[company]!.deposit(from: <-payment)

            if Bounty.stakesByCompany[company]![company] == nil {
                Bounty.stakesByCompany[company]![company] = 0.0
            }
            Bounty.stakesByCompany[company]![company] = Bounty.stakesByCompany[company]![company]! + Bounty.vaultByCompany[company]!.balance
            emit SponsorStaked(company: company, sponsor: company, amount: Bounty.vaultByCompany[company]!.balance, newPool: Bounty.vaultByCompany[company]!.balance)
        }

        // Mark an issue as accepted (unlock payment).
        access(all) fun acceptIssue(issueId: UInt64) {
            let company = self.mustCompany()
            pre { Bounty.issuesByCompany[company]![issueId] != nil: "issue does not exist" }

            let isr = &Bounty.issuesByCompany[company]![issueId] as &Issue?
            if isr == nil { panic("issue ref is nil") }

            isr!.accepted = true
            emit IssueAccepted(company: company, issueId: issueId, hacker: isr!.hacker, by: company)
        }

        // Pays any positive amount from the company pool to the issue's stored hackerReceiver, once accepted.
        access(all) fun payBounty(issueId: UInt64, amount: UFix64) {
            let company = self.mustCompany()
            pre { amount > 0.0: "amount must be > 0" }
            pre { Bounty.vaultByCompany[company]!.balance >= amount: "insufficient pool" }
            pre {
                let isr = Bounty.issuesByCompany[company]![issueId]
                return isr != nil && isr!.accepted
            }: "issue not accepted or does not exist"

            let issueRef = &Bounty.issuesByCompany[company]![issueId] as &Issue
            // Use the stored FlowToken receiver capability; cannot be redirected by function args.
            pre { issueRef.hackerReceiver.check(): "hacker receiver capability invalid" }
            let recv = issueRef.hackerReceiver.borrow() ?? panic("failed to borrow hacker receiver")

            let payout <- Bounty.vaultByCompany[company]!.withdraw(amount: amount)
            recv.deposit(from: <-payout)

            issueRef.paid = issueRef.paid + amount
            emit BountyPaid(company: company, issueId: issueId, hacker: issueRef.hacker, amount: amount)

            if issueRef.completed && issueRef.paid > 0.0 && !issueRef.notified {
                issueRef.notified = true
                let meta = Bounty.metaByCompany[company]!
                let msg = "\(meta.name) (\(meta.company)): issue #\(issueId) fixed and bounty paid."
                emit CompletionMessage(company: company, issueId: issueId, message: msg)
            }
        }

        // Owner sets completion status.
        access(all) fun setCompletion(issueId: UInt64, completed: Bool) {
            let company = self.mustCompany()
            pre { Bounty.issuesByCompany[company]![issueId] != nil: "issue does not exist" }

            let ref = &Bounty.issuesByCompany[company]![issueId] as &Issue
            ref.completed = completed
            emit CompletionStatusSet(company: company, issueId: issueId, hacker: ref.hacker, completed: completed)

            if completed && ref.paid > 0.0 && !ref.notified {
                ref.notified = true
                let meta = Bounty.metaByCompany[company]!
                let msg = "\(meta.name) (\(meta.company)): issue #\(issueId) fixed and bounty paid."
                emit CompletionMessage(company: company, issueId: issueId, message: msg)
            }
        }
    }

    // ─────────────────────────────
    // Init / Destroy
    // ─────────────────────────────
    init() {
        self.metaByCompany = {}
        self.vaultByCompany <- {}
        self.stakesByCompany = {}
        self.nextIssueIdByCompany = {}
        self.issuesByCompany = {}
    }

    destroy() {
        destroy self.vaultByCompany
    }

    // ─────────────────────────────
    // Company Admin creation & registration
    // (two-step to avoid squatting)
    // ─────────────────────────────

    /// Step 1: Company calls this in a setup tx to mint an Admin resource
    /// and store it under their account. The resource starts "unbound".
    access(all) fun createCompanyAdmin(): @CompanyAdmin {
        return <- create CompanyAdmin(company: nil)
    }

    /// Step 2: Register the company in the contract registry.
    /// - Requires a *private* capability to the stored Admin resource.
    /// - We derive the company Address from the capability's owner address.
    access(all) fun registerCompany(
        adminCap: Capability<&CompanyAdmin>,
        name: String,
        defaultPerPayout: UFix64
    ) {
        pre { defaultPerPayout >= 0.0: "defaultPerPayout must be non-negative" }
        // Borrow the Admin via the provided capability; this proves control.
        let admin = adminCap.borrow() ?? panic("invalid admin capability")

        let company: Address = adminCap.address
        pre { self.metaByCompany[company] == nil: "company already registered" }

        // Bind the admin to this company (one-time).
        admin.company = company

        // Initialize registry state & an empty FlowToken pool vault
        self.vaultByCompany[company] <-! FlowToken.createEmptyVault()
        self.metaByCompany[company] = CompanyMeta(company: company, name: name, defaultPerPayout: defaultPerPayout)
        self.stakesByCompany[company] = {}
        self.nextIssueIdByCompany[company] = 1
        self.issuesByCompany[company] = {}

        emit CompanyCreated(company: company, name: name, defaultPerPayout: defaultPerPayout)
    }

    // ─────────────────────────────
    // Owner-only actions (via Admin capability)
    // ─────────────────────────────

    /// Fund the company's bounty pool with FlowToken.
    access(all) fun sponsorStake(
        adminCap: Capability<&CompanyAdmin>,
        payment: @FlowToken.Vault
    ) {
        let admin = adminCap.borrow() ?? panic("invalid admin capability")
        admin.sponsorStake(payment: <-payment)
    }

    /// Accept an issue (unlocks payment).
    access(all) fun acceptIssue(
        adminCap: Capability<&CompanyAdmin>,
        issueId: UInt64
    ) {
        let admin = adminCap.borrow() ?? panic("invalid admin capability")
        admin.acceptIssue(issueId: issueId)
    }

    /// Pay a bounty to the stored hacker receiver for the issue.
    access(all) fun payBounty(
        adminCap: Capability<&CompanyAdmin>,
        issueId: UInt64,
        amount: UFix64
    ) {
        let admin = adminCap.borrow() ?? panic("invalid admin capability")
        admin.payBounty(issueId: issueId, amount: amount)
    }

    /// Set completion status for an issue.
    access(all) fun setCompletion(
        adminCap: Capability<&CompanyAdmin>,
        issueId: UInt64,
        completed: Bool
    ) {
        let admin = adminCap.borrow() ?? panic("invalid admin capability")
        admin.setCompletion(issueId: issueId, completed: completed)
    }

    // ─────────────────────────────
    // Public (hacker) action
    // ─────────────────────────────

    /// Submit a new issue to a registered company.
    ///
    /// SECURITY: We bind the "hacker identity" to the provided FlowToken
    /// receiver capability. Anyone can *attempt* to submit for any address,
    /// but unless they can present a *working receiver capability* for that
    /// address, `check()`/`borrow()` will fail here or at payout time.
    ///
    /// This also prevents payout redirection: the stored capability is used
    /// for all future payouts; no "to: Address" parameters are ever accepted.
    access(all) fun submitIssue(
        company: Address,
        summary: String,
        hackerReceiver: Capability<&FlowToken.Vault{FungibleToken.Receiver}>
    ): UInt64 {
        pre { self.metaByCompany[company] != nil: "company not registered" }
        pre { hackerReceiver.check(): "hacker must link a valid FlowToken receiver (e.g., /public/flowTokenReceiver)" }

        let sponsor = self.metaByCompany[company]!.company
        let issueId = self.nextIssueIdByCompany[company] ?? 1
        self.nextIssueIdByCompany[company] = issueId + 1

        let hackerAddr: Address = hackerReceiver.address

        self.issuesByCompany[company]![issueId] =
            Issue(
                sponsor: sponsor,
                hacker: hackerAddr,
                summary: summary,
                hackerReceiver: hackerReceiver
            )

        // If you still want a forum event, emit it here additionally.
        // emit ForumPosted(company: company, issueId: issueId, hacker: hackerAddr, sponsor: sponsor, summary: summary)

        emit IssueSubmitted(company: company, issueId: issueId, hacker: hackerAddr, summary: summary)
        return issueId
    }

    // ─────────────────────────────
    // Reads
    // ─────────────────────────────

    access(all) fun getCompanyMeta(company: Address): CompanyMeta {
        pre { self.metaByCompany[company] != nil: "company not registered" }
        return self.metaByCompany[company]!
    }

    access(all) fun getPoolBalance(company: Address): UFix64 {
        pre { self.metaByCompany[company] != nil: "company not registered" }
        return self.vaultByCompany[company]!.balance
    }

    access(all) fun getIssueStatus(company: Address, issueId: UInt64): {String: String} {
        pre { self.issuesByCompany[company]![issueId] != nil: "issue does not exist" }
        let isr = self.issuesByCompany[company]![issueId]!
        return {
            "hacker": isr.hacker.toString(),
            "accepted": isr.accepted.toString(),
            "completed": isr.completed.toString(),
            "paid": isr.paid.toString()
        }
    }
}
