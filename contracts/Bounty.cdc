import FungibleToken from 0xFLOW

access(all) contract Bounty {

    access(all) struct SponsorPosting {
        access(all) let summary: String
        access(all) let sponsorAddress: Address
        access(all) let company: String
        access(all) let trackDescription: String
        access(all) let bounty: UFix64

        init(summary: String, sponsorAddress: Address, company: String, trackDescription: String, bounty: UFix64) {
            self.summary = summary
            self.sponsorAddress = sponsorAddress
            self.company = company
            self.trackDescription = trackDescription
            self.bounty = bounty
        }
    }

    access(all) struct IssueTrack {
        access(all) var status: String
        access(all) var sponsorDecision: Bool

        init() {
            self.status = "pending"
            self.sponsorDecision = false
        }
    }

    access(all) event SponsorRegistered(address: Address, company: String)
    access(all) event TrackCreated(sponsor: Address, track: String, bounty: UFix64)
    access(all) event HackerSubmitted(hacker: Address, track: String, issue: String)
    access(all) event IssueAccepted(sponsor: Address, track: String, issue: String)
    access(all) event BountyPaid(hacker: Address, track: String, amount: UFix64)
    access(all) event TrackCompleted(track: String, company: String, issue: String)


    access(all) var stakes: {Address: {String: UFix64}}
    access(all) var sponsorPostings: {String: SponsorPosting}
    access(all) var issueTracks: {String: IssueTrack}
    access(all) var hackerSubmissions: {String: Address}

    access(self) var bountyVault: @FungibleToken.Vault

    init() {
        self.stakes = {}
        self.sponsorPostings = {}
        self.issueTracks = {}
        self.hackerSubmissions = {}
        self.bountyVault <- FungibleToken.createEmptyVault()
    }

    access(all) fun createTrack(payment: @F-T.Vault, summary: String, company: String, trackDescription: String) {
        pre {
            self.sponsorPostings[trackDescription] == nil: "Track already exists"
        }

        let sponsorAddress = self.account.address
        let bountyAmount = payment.balance

        self.bountyVault.deposit(from: <-payment)

        let newPosting = SponsorPosting(
            summary: summary,
            sponsorAddress: sponsorAddress,
            company: company,
            trackDescription: trackDescription,
            bounty: bountyAmount
        )

        self.sponsorPostings[trackDescription] = newPosting

        if self.stakes[sponsorAddress] == nil {
            self.stakes[sponsorAddress] = {}
        }

        self.stakes[sponsorAddress]![trackDescription] = bountyAmount
        self.issueTracks[trackDescription] = IssueTrack()

        emit TrackCreated(sponsor: sponsorAddress, track: trackDescription, bounty: bountyAmount)
    }

    access(all) fun submitBug(trackDescription: String, issueSummary: String) {
        pre {
            self.sponsorPostings[trackDescription] != nil: "Track does not exist"
            self.hackerSubmissions[trackDescription] == nil: "Bug already submitted for this track"
            self.issueTracks[trackDescription]!.status == "pending": "Submissions are closed for this track"
        }

        let hackerAddress = self.account.address
        self.hackerSubmissions[trackDescription] = hackerAddress
        self.issueTracks[trackDescription]!.status = "submitted"

        emit HackerSubmitted(hacker: hackerAddress, track: trackDescription, issue: issueSummary)
    }

    access(all) fun acceptSubmission(trackDescription: String, hackerReceiver: Capability<&{FungibleToken.Receiver}>) {
        pre {
            self.sponsorPostings[trackDescription] != nil: "Track does not exist"
            self.hackerSubmissions[trackDescription] != nil: "No bug submitted for this track"
            self.issueTracks[trackDescription]!.status == "submitted": "Submission not in review state"
            self.account.address == self.sponsorPostings[trackDescription]!.sponsorAddress: "Only the sponsor can accept"
        }

        self.issueTracks[trackDescription]!.sponsorDecision = true
        self.issueTracks[trackDescription]!.status = "accepted"

        let bountyAmount = self.sponsorPostings[trackDescription]!.bounty
        let hackerAddress = self.hackerSubmissions[trackDescription]!

        let payment <- self.bountyVault.withdraw(amount: bountyAmount)
        hackerReceiver.borrow()!.deposit(from: <-payment)

        emit IssueAccepted(sponsor: self.account.address, track: trackDescription, issue: "approved")
        emit BountyPaid(hacker: hackerAddress, track: trackDescription, amount: bountyAmount)
    }
}





