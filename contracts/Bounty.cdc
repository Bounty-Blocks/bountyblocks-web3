import FungibleToken from 0xFUNGIBLETOKEN
import FlowToken from 0xFLOWTOKEN

access(all) contract Bounty {

    access(all) struct SponsorPosting {
//sponsor posting information:
        access(all) let summary: String
        access(all) let sponsorAddress: Address
        access(all) let company: String
        access(all) let trackDescription: String
        access(all) let totalBounty: UFix64
        access(all) let perBugBounty: UFix64

        init(
            summary: String,
            sponsorAddress: Address,
            company: String,
            trackDescription: String,
            totalBounty: UFix64,
            perBugBounty: UFix64
        ) {
            self.summary = summary
            self.sponsorAddress = sponsorAddress
            self.company = company
            self.trackDescription = trackDescription
            self.totalBounty = totalBounty
            self.perBugBounty = perBugBounty
        }
    }
//tracker for the issues with the status (can be updated) and the sponsor's decision)
    access(all) struct IssueTrack {
        // "open" = submissions & accepts allowed; "closed" = no more accepts/cancel
        access(all) var status: String
        access(all) var sponsorDecision: Bool
//starts with an open status and the decision as a "no" before the sponsor makes their final decision
        init() {
            self.status = "open"
            self.sponsorDecision = false
        }
    }
//different self-explanitory events
    access(all) event TrackCreated(sponsor: Address, track: String, totalBounty: UFix64, perBugBounty: UFix64)
    access(all) event HackerSubmitted(hacker: Address, track: String, issue: String)
    access(all) event IssueAccepted(sponsor: Address, track: String, issue: String)
    access(all) event BountyPaid(hacker: Address, track: String, amount: UFix64)
    access(all) event TrackCanceled(track: String, sponsor: Address, amount: UFix64)

    // Per-sponsor -> per-track stake (kept from your version)
    access(all) var stakes: {Address: {String: UFix64}}
    access(all) var sponsorPostings: {String: SponsorPosting}
    access(all) var issueTracks: {String: IssueTrack}

    // Multiple submissions per track
    access(all) var hackerSubmissions: {String: [Address]}
    access(all) var submissionDetails: {String: {Address: String}}

    // 🔐 one vault per track (fixes global-mixing bug)
    access(self) var vaultByTrack: @{String: FlowToken.Vault}

    init() {
        self.stakes = {}
        self.sponsorPostings = {}
        self.issueTracks = {}
        self.hackerSubmissions = {}
        self.submissionDetails = {}
        self.vaultByTrack <- {}
    }

    destroy() {
        destroy self.vaultByTrack
    }

    // Sponsor creates and funds the track (TX must withdraw the FLOW and pass sponsor addr)
    access(all) fun createTrack(
        sponsor: Address,
        payment: @FlowToken.Vault,
        summary: String,
        company: String,
        trackDescription: String,
        perBugBounty: UFix64
    ) {
        pre {
            self.sponsorPostings[trackDescription] == nil: "Track already exists"
            perBugBounty > 0.0: "Per-bug bounty must be positive"
            payment.balance >= perBugBounty: "Prize pool must be at least one per-bug bounty"
        }

        let totalBounty = payment.balance

        // init per-track vault & deposit funds
        self.vaultByTrack[trackDescription] <-! FlowToken.createEmptyVault()
        self.vaultByTrack[trackDescription]!.deposit(from: <-payment)

        self.sponsorPostings[trackDescription] = SponsorPosting(
            summary: summary,
            sponsorAddress: sponsor,
            company: company,
            trackDescription: trackDescription,
            totalBounty: totalBounty,
            perBugBounty: perBugBounty
        )

        if self.stakes[sponsor] == nil {
            self.stakes[sponsor] = {}
        }
        self.stakes[sponsor]![trackDescription] = totalBounty

        self.issueTracks[trackDescription] = IssueTrack()
        self.hackerSubmissions[trackDescription] = []
        self.submissionDetails[trackDescription] = {}

        emit TrackCreated(sponsor: sponsor, track: trackDescription, totalBounty: totalBounty, perBugBounty: perBugBounty)
    }

    // Hacker submits (TX passes hacker addr)
    access(all) fun submitBug(trackDescription: String, issueSummary: String, hacker: Address) {
        pre {
            self.sponsorPostings[trackDescription] != nil: "Track does not exist"
            self.issueTracks[trackDescription]!.status == "open": "Submissions are closed for this track"
        }

        // Prevent duplicate submissions from the same hacker to the same track
        let subs = self.hackerSubmissions[trackDescription]!
        var already = false
        for addr in subs {
            if addr == hacker { already = true; break }
        }
        pre { !already: "You have already submitted a bug for this track" }

        self.hackerSubmissions[trackDescription]!.append(hacker)
        self.submissionDetails[trackDescription]![hacker] = issueSummary

        emit HackerSubmitted(hacker: hacker, track: trackDescription, issue: issueSummary)
    }

    // Sponsor accepts & pays exactly one per-bug bounty per call (multiple winners allowed)
    access(all) fun acceptSubmission(
        trackDescription: String,
        sponsor: Address,
        hacker: Address,
        hackerReceiver: Capability<&{FungibleToken.Receiver}>
    ) {
//edge case handling/error handling
        pre {
            self.sponsorPostings[trackDescription] != nil: "Track does not exist"
            self.submissionDetails[trackDescription]![hacker] != nil: "No submission by this hacker"
            self.issueTracks[trackDescription]!.status == "open": "Track is not open"
            self.sponsorPostings[trackDescription]!.sponsorAddress == sponsor: "Only the sponsor can accept"
            self.vaultByTrack[trackDescription]!.balance >= self.sponsorPostings[trackDescription]!.perBugBounty: "Not enough bounty left"
        }

        let perBug = self.sponsorPostings[trackDescription]!.perBugBounty

        let receiver = hackerReceiver.borrow() ?? panic("bad receiver cap")
        let payment <- self.vaultByTrack[trackDescription]!.withdraw(amount: perBug)
        receiver.deposit(from: <-payment)

        // optional flag you had; keeping it here
        self.issueTracks[trackDescription]!.sponsorDecision = true

        // Auto-close when pool can’t fund another winner
        if self.vaultByTrack[trackDescription]!.balance < perBug {
            self.issueTracks[trackDescription]!.status = "closed"
        }

        emit IssueAccepted(sponsor: sponsor, track: trackDescription, issue: "approved")
        emit BountyPaid(hacker: hacker, track: trackDescription, amount: perBug)
    }

    // Sponsor cancels remaining pool back to themselves, gets remaining money back
    access(all) fun cancelTrack(
        trackDescription: String,
        sponsor: Address,
        sponsorReceiver: Capability<&{FungibleToken.Receiver}>
    ) {
        pre {
            self.sponsorPostings[trackDescription] != nil: "Track does not exist"
            self.sponsorPostings[trackDescription]!.sponsorAddress == sponsor: "Only the sponsor can cancel"
            self.issueTracks[trackDescription]!.status == "open": "Track already closed"
        }

        let remaining = self.vaultByTrack[trackDescription]!.balance
        let receiver = sponsorReceiver.borrow() ?? panic("bad receiver cap")

        let payout <- self.vaultByTrack[trackDescription]!.withdraw(amount: remaining)
        receiver.deposit(from: <-payout)

        self.issueTracks[trackDescription]!.status = "closed"

        emit TrackCanceled(track: trackDescription, sponsor: sponsor, amount: remaining)
    }
}
