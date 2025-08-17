import "NonFungibleToken"
import "BountyBlocksNFTContract"

transaction(
    recipient: Address
) {

    /// local variable for storing the minter reference
    let minter: &BountyBlocksNFTContract.NFTMinter

    /// Reference to the receiver's collection
    let recipientCollectionRef: &{NonFungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        
        // borrow a reference to the NFTMinter resource in storage
        self.minter = signer.storage.borrow<&BountyBlocksNFTContract.NFTMinter>(from: BountyBlocksNFTContract.MinterStoragePath)
            ?? panic("Account does not store an object at the specified path")

        // Borrow the recipient's public NFT collection reference
        self.recipientCollectionRef = getAccount(recipient).capabilities.borrow<&{NonFungibleToken.Receiver}>(
                BountyBlocksNFTContract.CollectionPublicPath
            ) ?? panic("Could not get receiver reference to the NFT Collection")
    }

    execute {
        // Mint the NFT and deposit it to the recipient's collection
        let mintedNFT <- self.minter.createNFT()
        self.recipientCollectionRef.deposit(token: <-mintedNFT)
    }
}