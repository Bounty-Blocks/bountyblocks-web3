import "BountyBlocksNFTContract"
import "NonFungibleToken"

transaction {

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue, UnpublishCapability) &Account) {
        
        // Return early if the account already has a collection
        if signer.storage.borrow<&BountyBlocksNFTContract.Collection>(from: BountyBlocksNFTContract.CollectionStoragePath) != nil {
            return
        }

        // Create a new empty collection
        let collection <- BountyBlocksNFTContract.createEmptyCollection(nftType: Type<@BountyBlocksNFTContract.BountyBlocksNFT>())

        // save it to the account
        signer.storage.save(<-collection, to: BountyBlocksNFTContract.CollectionStoragePath)

        let collectionCap = signer.capabilities.storage.issue<&BountyBlocksNFTContract.Collection>(BountyBlocksNFTContract.CollectionStoragePath)
        signer.capabilities.publish(collectionCap, at: BountyBlocksNFTContract.CollectionPublicPath)
    }
}