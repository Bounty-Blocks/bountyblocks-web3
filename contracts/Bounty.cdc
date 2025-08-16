import FungibleToken from 0xFUNGIBLETOKEN
import FlowToken from 0xFLOWTOKEN

access(all) contract Bounty {

    // ---------- Events ----------
    access(all) event CompanyCreated(company: Address, name: String, defaultPerPayout: UFix64)
    access(all) event SponsorStaked(company: Address, sponsor: Address, amount: UFix64, newPool: UFix64)
    access(all) event ForumPosted(company: Address, hacker: Address, sponsor: Address, summary: String)
    access(all) event IssueSubmitted(company: Address, hacker: Address, summary: String)
    access(all) event IssueAccepted(company: Address, hacker: Address, by: Address)
    access(all) event BountyPaid(company: Address, hacker: Address, amount: UFix64)
    access(all) event CompletionStatusSet(company: Address, hacker: Address, completed: Bool)
    access(all) event CompletionMessage(company: Address, message: String)

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

    access(all) struct ForumPost {
        access(all) let summary: String
        access(all) let sponsor: Address
        access(all) let hacker: Address
        init(summary: String, sponsor: Address, hacker: Address) {
            self.summary = summary
            self.sponsor = sponsor
            self.hacker = hacker
        }
    }

    access(all) struct Issue {
        access(all) let hacker: Address
        access(all) let summary: String
        access(all) var accepted: Bool
        access(all) var completed: Bool
        access(all) var paid: UFix64
        init(hacker: Address, summary: String) {
            self.hacker = hacker
            self.summary = summary
            self.accepted = false
            self.completed = false
            self.paid = 0.0
        }
    }

    // ---------- Storage (keyed by company address) ----------
    access(all) var metaByCompany: {Address: CompanyMeta}
    access(self) var vaultByCompany: @{Address: FlowToken.Vault}        // pooled funds per company
    access(all) var stakesByCompany: {Address: {Address: UFix64}}       // company -> sponsor -> amount
    access(all) var forumByCompany: {Address: [ForumPost]}
    access(all) var issuesByCompany: {Address: {Address: Issue}}        // company -> hacker -> issue

    init() {
        self.metaByCompany = {}
        self.vaultByCompany <- {}
        self.stakesByCompany = {}
        self.forumByCompany = {}
        self.issuesByCompany = {}
    }

    destroy() {
        destroy self.vaultByCompany
    }

    // ---------- Company setup ----------
    // Register a company bounty pool (no funds required here)
    access(all) fun registerCompany(company: Address, name: String, defaultPerPayout: UFix64) {
        pre {
            self.metaByCompany[company] == nil: "company already registered"
            defaultPerPayout >= 0.0: "defaultPerPayout must be non-negative"
        }
        self.vaultByCompany[company] <-! FlowToken.createEmptyVault()
        self.metaByCompany[company] = CompanyMeta(company: company, name: name, defaultPerPayout: defaultPerPayout)
        self.stakesByCompany[company] = {}
        self.forumByCompany[company] = []
        self.issuesByCompany[company] = {}
        emit CompanyCreated(company: company, name: name, defaultPerPayout: defaultPerPayout)
    }

    // ---------- Sponsors (companies) stake to their own pool ----------
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

    // ---------- Hackers: forum + submission ----------
    access(all) fun submitIssue(company: Address, hacker: Address, summary: String) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.issuesByCompany[company]![hacker] == nil: "already submitted to this company"
        }
        let sponsor = self.metaByCompany[company]!.company
        let post = ForumPost(summary: summary, sponsor: sponsor, hacker: hacker)
        self.forumByCompany[company]!.append(post)
        emit ForumPosted(company: company, hacker: hacker, sponsor: sponsor, summary: summary)

        self.issuesByCompany[company]![hacker] = Issue(hacker: hacker, summary: summary)
        emit IssueSubmitted(company: company, hacker: hacker, summary: summary)
    }

    // ---------- Bug tracking (company controls) ----------
    access(all) fun acceptIssue(company: Address, owner: Address, hacker: Address) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.metaByCompany[company]!.company == owner: "only the company can accept"
            self.issuesByCompany[company]![hacker] != nil: "no submission from this hacker"
        }
        self.issuesByCompany[company]![hacker]!.accepted = true
        emit IssueAccepted(company: company, hacker: hacker, by: owner)
    }

    access(all) fun setCompletion(company: Address, owner: Address, hacker: Address, completed: Bool) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.metaByCompany[company]!.company == owner: "only the company can set completion"
            self.issuesByCompany[company]![hacker] != nil: "no submission from this hacker"
        }
        self.issuesByCompany[company]![hacker]!.completed = completed
        emit CompletionStatusSet(company: company, hacker: hacker, completed: completed)

        let issue = self.issuesByCompany[company]![hacker]!
        if completed && issue.paid > 0.0 {
            let meta = self.metaByCompany[company]!
            let msg = "\(meta.name) (\(meta.company)): issue fixed and bounty paid."
            emit CompletionMessage(company: company, message: msg)
        }
    }

    // ---------- Payment (company controls; unlocked by acceptance) ----------
    access(all) fun payBounty(
        company: Address,
        owner: Address,
        hacker: Address,
        amount: UFix64,
        hackerReceiver: Capability<&{FungibleToken.Receiver}>
    ) {
        pre {
            self.metaByCompany[company] != nil: "company not registered"
            self.metaByCompany[company]!.company == owner: "only the company can pay"
            self.issuesByCompany[company]![hacker] != nil: "no submission from this hacker"
            self.issuesByCompany[company]![hacker]!.accepted: "issue not accepted"
            amount > 0.0: "amount must be > 0"
            self.vaultByCompany[company]!.balance >= amount: "insufficient pool"
        }
        let recv = hackerReceiver.borrow() ?? panic("bad receiver cap")
        let payout <- self.vaultByCompany[company]!.withdraw(amount: amount)
        recv.deposit(from: <-payout)

        self.issuesByCompany[company]![hacker]!.paid = self.issuesByCompany[company]![hacker]!.paid + amount
        emit BountyPaid(company: company, hacker: hacker, amount: amount)

        let meta = self.metaByCompany[company]!
        let issue = self.issuesByCompany[company]![hacker]!
        if issue.completed && issue.paid > 0.0 {
            let msg = "\(meta.name) (\(meta.company)): issue fixed and bounty paid."
            emit CompletionMessage(company: company, message: msg)
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

    access(all) fun getIssueStatus(company: Address, hacker: Address): {String: String} {
        pre { self.issuesByCompany[company]![hacker] != nil: "no submission from this hacker" }
        let isr = self.issuesByCompany[company]![hacker]!
        return {
            "accepted": isr.accepted.toString(),
            "completed": isr.completed.toString(),
            "paid": isr.paid.toString()
        }
    }

    access(all) fun getForum(company: Address): [ForumPost] {
        pre { self.metaByCompany[company] != nil: "company not registered" }
        return self.forumByCompany[company]!
    }

    access(all) fun getStakeOf(company: Address, sponsor: Address): UFix64 {
        pre { self.metaByCompany[company] != nil: "company not registered" }
        return self.stakesByCompany[company]![sponsor] ?? 0.0
    }
}
