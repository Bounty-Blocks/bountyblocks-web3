import "NonFungibleToken"
import "BountyBlocksNFTContract"

access(all) fun main(address: Address): [UInt64] {
    let account = getAccount(address)

    let collectionRef = account.capabilities.borrow<&{NonFungibleToken.Collection}>(
            BountyBlocksNFTContract.CollectionPublicPath
        ) ?? panic("Could not borrow capability from collection at specified path")

    return collectionRef.getIDs()
}