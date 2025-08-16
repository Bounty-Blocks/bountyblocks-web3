import FungibleToken from 0xFUNGIBLETOKEN
import FlowToken from 0xFLOWTOKEN

access(all) contract Bounty {

    // ---------- Events ----------
    access(all) event CompanyCreated(company: Address, name: String, defaultPerPayout: UFix64)
    access(all) event SponsorStaked(company: Address, sponsor: Address, amount: UFix64, newPool: UFix64)

    // Forum + lifecycle carry the per-company issueId
    access(all) event ForumPosted(company: Address, issueId: UInt64, hacker: Address, sponsor: Address, summary: String)
    access(all) event IssueSubmitted(company: Address, issueId: UInt64, hacker: Address, summary: String)
    access(all) event IssueAccepted(company: Address, issueId: UInt64, hacker: Address, by: Address)
    access(all) event BountyPaid(company: Address, issueId: UInt64, hacker: Address, amount: UFix64)
    access(all) event CompletionStatusSet(company: Address, issueId: UInt64, hacker: Address, completed: Bool)
    access(all) event CompletionMessage(company: Address, issueId: UInt64, message: String)

    // ---------- Data ----------
    access(all) struct CompanyMeta {
        access(all) let company: Address          // owner/controller of this pool
        access(all) let name: String              // display label
        access(all) let defaultPerPayout: UFix64  // advisory default amount
        init(company: Address, name: String, defaultPerPayout: UFix64) {
            self.company = company
            self.name = name
            self.defaultPerPayout = defaultPerPayout
        }
    }

    access(all) struct Issue {
        access(all) let sponsor: Address   // the company this issue belongs to
        access(all) let hacker: Address    // submitting address
        access(all) let summary: String    // short public summary
        access(all) var accepted: Bool     // set true by sponsor to unlock payment
        access(all) var completed: Bool    // set true by sponsor when fixed
        access(all) var paid: UFix64       // total FLOW paid for this issue
        access(all) var notified: Bool     // completion message already emitted
        init(sponsor: Address, hacker: Address, summary: String) {
            self.sponsor   = sponsor
            self.hacker    = hacker
            self.summary   = summary
            self.accepted  = false
            self.completed = false
            self.paid      = 0.0
            self.notified  = false
        }
    }

    // ---------- Storage (keyed by company) ----------
    access(all) var metaByCompany: {Address: CompanyMeta}
    access(self) var vaultByCompany: @{Address: FlowToken.Vault}           // pooled FLOW per company
    access(all) var stakesByCompany: {Address: {Address: UFix64}}          // company -> sponsor -> amount (kept for transparency)
    access(self) var nextIssueIdByCompany: {Address: UInt64}               // company -> next issueId
    access(all) var issuesByCompany: {Address: {UInt64: Issue}}            // company -> issueId -> Issue

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

    // ---------- Company setup ----------
    access(all) fun registerCompany(company: Address, name: String, defaultPerPayout: UFix64) {
        pre {
            self.metaByCompany[company] == nil: "company already registered"
            defaultPerPayout >= 0.0: "defaultPerPayout must be non-negative"
        }
        self.vaultByCompany[company] <-! FlowToken.createEmptyVault()
        self.metaByCompany[company] = CompanyMeta(company: company, name: name, defaultPerPayout: defaultPerPayout)
        self.stakesByCompany[company] = {}
        self.nextIssueIdByCompany[company] = 1
        self.issuesByCompany[company] = {}
        emit CompanyCreated(company: company, name: name, defaultPerPayout: defaultPerPayout)
    }

    // ---------- Stake (company funds its own pool) ----------
    access(all) fun sponsorStake(company: Address, sponsor: Address, payment: @FlowToken.Vault) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            sponsor == company: "sponsor can only stake to their own company"
            payment.balance > 0.0: "stake must be > 0"
        }
        let amt = payment.balance
        self.vaultByCompany[company]!.deposit(from: <-payment)

        if self.stakesByCompany[company]![sponsor] == nil {
            self.stakesByCompany[company]![sponsor] = 0.0
        }
        self.stakesByCompany[company]![sponsor] = self.stakesByCompany[company]![sponsor]! + amt

        emit SponsorStaked(company: company, sponsor: sponsor, amount: amt, newPool: self.vaultByCompany[company]!.balance)
    }

    // ---------- Submit (hacker) ----------
    // Returns the per-company issueId (1,2,3,...) for future reference.
    access(all) fun submitIssue(company: Address, hacker: Address, summary: String): UInt64 {
        pre { self.metaByCompany[company] != nil: "company not registered" }

        let sponsor = self.metaByCompany[company]!.company
        let issueId = self.nextIssueIdByCompany[company] ?? 1
        self.nextIssueIdByCompany[company] = issueId + 1

        self.issuesByCompany[company]![issueId] = Issue(sponsor: sponsor, hacker: hacker, summary: summary)

        emit ForumPosted(company: company, issueId: issueId, hacker: hacker, sponsor: sponsor, summary: summary)
        emit IssueSubmitted(company: company, issueId: issueId, hacker: hacker, summary: summary)
        return issueId
    }

    // ---------- Accept (owner) ----------
    access(all) fun acceptIssue(company: Address, owner: Address, issueId: UInt64) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.metaByCompany[company]!.company == owner: "only the company can accept"
            self.issuesByCompany[company]![issueId] != nil: "issue does not exist"
        }
        self.issuesByCompany[company]![issueId]!.accepted = true
        let hacker = self.issuesByCompany[company]![issueId]!.hacker
        emit IssueAccepted(company: company, issueId: issueId, hacker: hacker, by: owner)
    }

    // ---------- Pay (owner) ----------
    // Pays any positive amount from the company pool to the issue's hacker, once accepted.
    access(all) fun payBounty(
        company: Address,
        owner: Address,
        issueId: UInt64,
        amount: UFix64,
        hackerReceiver: Capability<&{FungibleToken.Receiver}>
    ) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.metaByCompany[company]!.company == owner: "only the company can pay"
            self.issuesByCompany[company]![issueId] != nil: "issue does not exist"
            self.issuesByCompany[company]![issueId]!.accepted: "issue not accepted"
            amount > 0.0: "amount must be > 0"
            self.vaultByCompany[company]!.balance >= amount: "insufficient pool"
        }

        let issueRef = self.issuesByCompany[company]![issueId]!
        let recv = hackerReceiver.borrow() ?? panic("bad receiver cap")

        let payout <- self.vaultByCompany[company]!.withdraw(amount: amount)
        recv.deposit(from: <-payout)

        issueRef.paid = issueRef.paid + amount
        emit BountyPaid(company: company, issueId: issueId, hacker: issueRef.hacker, amount: amount)

        // If already completed, emit completion message once
        if issueRef.completed && issueRef.paid > 0.0 && !issueRef.notified {
            issueRef.notified = true
            let meta = self.metaByCompany[company]!
            let msg = "\(meta.name) (\(meta.company)): issue #\(issueId) fixed and bounty paid."
            emit CompletionMessage(company: company, issueId: issueId, message: msg)
        }
    }

    // ---------- Complete (owner) ----------
    access(all) fun setCompletion(company: Address, owner: Address, issueId: UInt64, completed: Bool) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.metaByCompany[company]!.company == owner: "only the company can set completion"
            self.issuesByCompany[company]![issueId] != nil: "issue does not exist"
        }
        let ref = self.issuesByCompany[company]![issueId]!
        ref.completed = completed
        emit CompletionStatusSet(company: company, issueId: issueId, hacker: ref.hacker, completed: completed)

        // If already paid, emit completion message once
        if completed && ref.paid > 0.0 && !ref.notified {
            ref.notified = true
            let meta = self.metaByCompany[company]!
            let msg = "\(meta.name) (\(meta.company)): issue #\(issueId) fixed and bounty paid."
            emit CompletionMessage(company: company, issueId: issueId, message: msg)
        }
    }

    // ---------- Reads ----------
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
