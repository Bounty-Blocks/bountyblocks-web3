import "BountyBlocksNFTContract"
import "NonFungibleToken"

transaction(recipient: Address, withdrawID: UInt64) {

    /// Reference to the withdrawer's collection
    let withdrawRef: auth(NonFungibleToken.Withdraw) &{NonFungibleToken.Collection}

    /// Reference of the collection to deposit the NFT to
    let receiverRef: &{NonFungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {

        // borrow a reference to the signer's NFT collection
        self.withdrawRef = signer.storage.borrow<auth(NonFungibleToken.Withdraw) &{NonFungibleToken.Collection}>(
                from: BountyBlocksNFTContract.CollectionStoragePath
            ) ?? panic("Account does not store an object at the specified path")

        // get the recipients public account object
        let recipient = getAccount(recipient)

        // borrow a public reference to the receivers collection
        let receiverCap = recipient.capabilities.get<&{NonFungibleToken.Receiver}>(BountyBlocksNFTContract.CollectionPublicPath)

        self.receiverRef = receiverCap.borrow()
            ?? panic("Could not borrow reference to the recipient's receiver")
    }

    execute {
        let nft <- self.withdrawRef.withdraw(withdrawID: withdrawID)
        self.receiverRef.deposit(token: <-nft)
    }
}