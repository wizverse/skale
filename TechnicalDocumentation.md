# Wizverse Smart Contracts Technical Documentation

This document provides technical documentation for the public and external functions within the Wizverse smart contracts ecosystem.

## `WizverseCore.sol`

The `WizverseCore` contract is the central hub of the Wizverse ecosystem. It manages game sessions, platform assets, fee distribution, and interactions between different modules like `WizverseSessions` and `WizverseNFTManager`.

### Public/External Functions

#### `constructor(address initialOwner, address _treasury, address _backendSigner, address _sessions, address _nftManager)`
- **Description**: Initializes the `WizverseCore` contract with necessary addresses.
- **Parameters**:
    - `initialOwner`: The address of the contract owner.
    - `_treasury`: The address for receiving fee payments.
    - `_backendSigner`: The address of the backend signer for certain operations.
    - `_sessions`: The address of the `WizverseSessions` contract.
    - `_nftManager`: The address of the `WizverseNFTManager` contract.
- **Modifiers**: `Ownable`

#### `setTreasury(address _treasury)`
- **Description**: Updates the treasury address.
- **Parameters**:
    - `_treasury`: The new treasury address.
- **Modifiers**: `onlyOwner`

#### `setNFTContract(address _nftContract)`
- **Description**: Updates the NFT contract address.
- **Parameters**:
    - `_nftContract`: The new NFT contract address.
- **Modifiers**: `onlyOwner`

#### `setMinFeeUsd(uint256 _fee)`
- **Description**: Sets the minimum fee in USD for operations.
- **Parameters**:
    - `_fee`: The new minimum fee in USD (with 18 decimals).
- **Modifiers**: `onlyOwner`

#### `setRestorationFeeUsd(uint256 _newFee)`
- **Description**: Sets the fee in USD for wizard health restoration.
- **Parameters**:
    - `_newFee`: The new fee in USD (with 18 decimals).
- **Modifiers**: `onlyOwner`

#### `setPercentFeesLeavedForPlayers(uint256 _percent)`
- **Description**: Sets the percentage of fees left for platform owners (out of 10000).
- **Parameters**:
    - `_percent`: The new percentage.
- **Modifiers**: `onlyOwner` or `isGameServer`

#### `setPlatformOwnerIncomePercent(uint256 _percent)`
- **Description**: Sets the percentage of platform income that goes directly to the platform owner.
- **Parameters**:
    - `_percent`: The new percentage (out of 10000).
- **Modifiers**: `onlyOwner`

#### `updatePlatformAssets(uint256 platformTokenId, uint256 amount, address token)`
- **Description**: Updates the asset balance for a specific platform. A portion of the assets can be paid out directly to the platform's original owner.
- **Parameters**:
    - `platformTokenId`: The token ID of the platform.
    - `amount`: The amount of assets to add.
    - `token`: The address of the token (`address(0)` for native currency).
- **Modifiers**: Called only by `nftManager`.

#### `distributePlatformFee(uint256 platformTokenId, uint256 amount, address token)`
- **Description**: Distributes a fee amount to a single platform.
- **Parameters**:
    - `platformTokenId`: The platform to receive the fee.
    - `amount`: The amount to distribute.
    - `token`: The token address (`address(0)` for native currency).
- **Modifiers**: `onlyOwner` or `isGameServer`

#### `getPlatformAssets(uint256 platformTokenId)`
- **Description**: Retrieves the asset balances for a specific platform.
- **Parameters**:
    - `platformTokenId`: The token ID of the platform.
- **Returns**:
    - `native`: The native currency balance.
    - `tokens`: An array of supported token addresses with balances.
    - `balances`: An array of corresponding token balances.

#### `checkPlatformHasAssets(uint256 platformTokenId)`
- **Description**: Checks if a platform has any assets.
- **Parameters**:
    - `platformTokenId`: The token ID of the platform.
- **Returns**:
    - `bool`: `true` if the platform has assets, `false` otherwise.

#### `getPlatformCount()`
- **Description**: Gets the total count of platforms that hold assets.
- **Returns**:
    - `uint256`: The number of platforms with assets.

#### `payForOperation(bytes4 _operation)`
- **Description**: A generic payable function to receive native currency for an operation. Funds are forwarded to the treasury.
- **Parameters**:
    - `_operation`: The 4-byte signature of the operation being paid for (currently unused).
- **Returns**:
    - `bool`: `true` on success.

#### `payForOperationWithToken(bytes4 _operation, address _token, uint256 _amount)`
- **Description**: A generic function to receive ERC20 tokens for an operation. Tokens are transferred to the treasury.
- **Parameters**:
    - `_operation`: The 4-byte signature of the operation (currently unused).
    - `_token`: The address of the ERC20 token.
    - `_amount`: The amount of tokens to pay.
- **Returns**:
    - `bool`: `true` on success.

#### `createSessionSolo(...)`
- **Description**: Creates a solo game session by delegating the call to the `WizverseSessions` contract.
- **Parameters**:
    - `characterTokenId`: The wizard NFT token ID.
    - `weaponTokenId`: The weapon NFT token ID.
    - `platformTokenId`: The platform NFT token ID.
    - `player`: The player's address.
- **Modifiers**: `onlyGameServer`
- **Returns**:
    - `sessionId`: The ID of the newly created session.

#### `createSessionTeam(...)`
- **Description**: Creates a team-based game session by delegating the call to `WizverseSessions`.
- **Parameters**:
    - `teamCharacterTokenIds`: Array of wizard token IDs for the team.
    - `teamWeaponTokenIds`: Array of weapon token IDs for the team.
    - `platformTokenId`: The platform NFT token ID.
    - `players`: Array of player addresses.
- **Modifiers**: `onlyGameServer`
- **Returns**:
    - `sessionId`: The ID of the newly created session.

#### `createSessionMultiplayer(...)`
- **Description**: Creates a multiplayer game session for two teams by delegating to `WizverseSessions`.
- **Parameters**:
    - `teamCharacterTokenIds`: A 2D array containing character token IDs for two teams.
    - `teamWeaponTokenIds`: A 2D array containing weapon token IDs for two teams.
    - `platformTokenId`: The platform NFT token ID.
    - `players`: Array of player addresses.
- **Modifiers**: `onlyGameServer`
- **Returns**:
    - `sessionId`: The ID of the newly created session.

#### `updateSession(uint256 sessionId, uint8 outcome, uint256[] calldata winnerTokenIds, bool completed)`
- **Description**: Updates the state of a game session by delegating to `WizverseSessions`.
- **Parameters**:
    - `sessionId`: The ID of the session to update.
    - `outcome`: The outcome of the session.
    - `winnerTokenIds`: An array of token IDs for the winners.
    - `completed`: A boolean indicating if the session is completed.
- **Modifiers**: `onlyGameServer`

#### `addNFTBatchTo(uint256 platformTokenId, uint256[] calldata tokenIds)`
- **Description**: Deposits a batch of NFTs and native currency into the ecosystem, allocating a percentage of the payment to a specified platform. Delegates to `WizverseNFTManager`.
- **Parameters**:
    - `platformTokenId`: The platform to receive a share of the fees.
    - `tokenIds`: An array of NFT token IDs to deposit.

#### `addNFTBatchTokenTo(...)`
- **Description**: Deposits a batch of NFTs and ERC20 tokens, allocating a percentage of the payment to a platform. Delegates to `WizverseNFTManager`.
- **Parameters**:
    - `platformTokenId`: The platform to receive a share of the fees.
    - `tokenIds`: An array of NFT token IDs to deposit.
    - `token`: The ERC20 token address for payment.
    - `tokenAmount`: The amount of tokens to pay.

#### `returnNFT(uint256 tokenId)`
- **Description**: Allows the original owner to withdraw a deposited NFT from the core contract. Verifies with `WizverseNFTManager` before transferring.
- **Parameters**:
    - `tokenId`: The token ID of the NFT to return.
- **Returns**:
    - `bool`: `true` on success.

#### `claimMagicBox()`
- **Description**: A function for users to claim a "magic box". Emits an event.

#### `claimMagicBoxPayable()`
- **Description**: A payable function for users to claim a "magic box", returning any sent value to the sender. Emits an event with the value.

#### `receive()`
- **Description**: Fallback function to receive native currency payments.

#### `setGameServers(address[] calldata _gameServers)`
- **Description**: Authorizes multiple addresses as game servers.
- **Parameters**:
    - `_gameServers`: An array of addresses to be set as game servers.
- **Modifiers**: `onlyOwner`

#### `setNativePaymentsDisabled(bool _disabled)`
- **Description**: Enables or disables native currency payments for operations.
- **Parameters**:
    - `_disabled`: `true` to disable, `false` to enable.
- **Modifiers**: `onlyOwner`

#### `getNFTsByWallet(address wallet)`
- **Description**: Retrieves detailed data for all NFTs associated with a wallet, including both deposited and wallet-held NFTs.
- **Parameters**:
    - `wallet`: The address of the wallet to query.
- **Returns**:
    - `nfts`: An array of `NFTData` structs containing detailed information about each NFT.

#### `getNFTsByWalletSimpleDeposited(address wallet)`
- **Description**: Retrieves an array of token IDs for NFTs deposited by a specific wallet.
- **Parameters**:
    - `wallet`: The address of the wallet.
- **Returns**:
    - `tokenIds`: An array of deposited token IDs.

#### `withdrawEther()`
- **Description**: Allows the contract owner to withdraw the entire native currency balance of the contract.
- **Modifiers**: `onlyOwner`

#### `withdrawTokens(address tokenContract, address recipient)`
- **Description**: Allows the contract owner to withdraw the entire balance of a specific ERC20 token to a recipient.
- **Parameters**:
    - `tokenContract`: The address of the ERC20 token.
    - `recipient`: The address to receive the tokens.
- **Modifiers**: `onlyOwner`

#### `getDepositedPlatformsWithStats()`
- **Description**: Returns detailed information for all platform NFTs currently deposited in the Core contract, including asset balances and session statistics.
- **Returns**:
    - `platforms`: An array of `PlatformInfo` structs with detailed data.

#### `getDepositedPlatforms()`
- **Description**: Returns an array of token IDs for all platform NFTs currently deposited in the Core contract.
- **Returns**:
    - `tokenIds`: An array of platform token IDs.

#### `checkPlatformHasActiveSessions(uint256 platformTokenId)`
- **Description**: Checks if a platform has any active game sessions by delegating to `WizverseSessions`.
- **Parameters**:
    - `platformTokenId`: The token ID of the platform.
- **Returns**:
    - `hasActiveSessions`: `true` if there are active sessions.
    - `activeSessionCount`: The number of active sessions.

#### `getActivePlatformSessions(uint256 platformTokenId, uint256 offset, uint256 limit)`
- **Description**: Retrieves active game sessions for a specific platform with pagination. Delegates to `WizverseSessions`.
- **Parameters**:
    - `platformTokenId`: The platform token ID.
    - `offset`: Starting index for pagination.
    - `limit`: Maximum number of session IDs to return.
- **Returns**:
    - `sessionIds`: An array of active session IDs.

#### `getPlatformStats(uint256 platformTokenId)`
- **Description**: Gathers and returns aggregated statistics for a specific platform, combining data from `WizverseCore` and `WizverseSessions`.
- **Parameters**:
    - `platformTokenId`: The platform token ID.
- **Returns**:
    - `stats`: A `PlatformStats` struct containing the aggregated data.

#### `distributeWinnerRewardsToEscrow(...)`
- **Description**: Distributes rewards to winners by transferring funds from a platform's asset pool to the `WizverseSessions` contract for escrow.
- **Parameters**:
    - `platformTokenId`: The platform providing the rewards.
    - `winners`: An array of winner wallet addresses.
    - `amounts`: An array of corresponding reward amounts.
    - `token`: The address of the reward token (`address(0)` for native).
- **Modifiers**: Called only by `WizverseSessions`.
- **Returns**:
    - `bool`: `true` on success.

#### `requestToClaimRewards()`
- **Description**: Allows a user to request claiming their rewards from completed sessions. Delegates to `WizverseSessions`.
- **Returns**:
    - `bool`: `true` on success.

#### `getOriginalOwner(uint256 tokenId)`
- **Description**: Retrieves the original owner of a deposited NFT by querying the `WizverseNFTManager`.
- **Parameters**:
    - `tokenId`: The token ID of the NFT.
- **Returns**:
    - `address`: The original owner's address.

#### `getWalletRewardsCombined(address wallet)`
- **Description**: A convenience view function that fetches all reward-related information for a wallet in a single call.
- **Parameters**:
    - `wallet`: The wallet address to query.
- **Returns**:
    - `hasWaiting`: `true` if rewards are queued in escrow.
    - `waitingRewards`: Details of rewards in escrow.
    - `platformIds`: Platform IDs associated with waiting rewards.
    - `canRequest`: `true` if the wallet has unclaimed rewards they can request.
    - `pendingRewards`: Details of pending (not yet escrowed) rewards.

#### `restoreHealth(uint256 tokenId)`
- **Description**: Allows a user to pay in native currency to restore a wizard's health. Delegates logic to `WizverseNFTManager`.
- **Parameters**:
    - `tokenId`: The token ID of the wizard NFT.

#### `restoreHealthToken(uint256 tokenId, address token)`
- **Description**: Allows a user to pay with an ERC20 token to restore a wizard's health. Delegates logic to `WizverseNFTManager`.
- **Parameters**:
    - `tokenId`: The token ID of the wizard NFT.
    - `token`: The address of the ERC20 token for payment.

#### `createSignin(address wallet)`
- **Description**: Creates a sign-in record for a wallet by delegating to `WizverseSessions`.
- **Parameters**:
    - `wallet`: The wallet address to sign-in.
- **Modifiers**: `onlyGameServer`

#### `getSigninTimestamp(address wallet)`
- **Description**: Retrieves the sign-in timestamp for a wallet from `WizverseSessions`.
- **Parameters**:
    - `wallet`: The wallet address.
- **Returns**:
    - `uint256`: The Unix timestamp of the sign-in.

#### `updateWizardAttributesCore(...)`
- **Description**: Updates the attributes of a wizard NFT by calling the `WizverseNFT` contract.
- **Parameters**:
    - `tokenId`: The wizard's token ID.
    - ... (various wizard attributes).
- **Modifiers**: `onlyGameServer`

#### `getActiveSessions(address player, uint256 offset, uint256 limit)`
- **Description**: Retrieves active game sessions for a player with pagination. Delegates to `WizverseSessions`.
- **Parameters**:
    - `player`: The player's address (`address(0)` for all active sessions).
    - `offset`: Starting index for pagination.
    - `limit`: Maximum number of sessions to return.
- **Returns**:
    - `uint256[]`: An array of active session IDs.

## `WizverseNFT.sol`

This contract implements the ERC721 standard for Wizverse NFTs, including wizards, weapons, and platforms. It manages NFT minting, attributes, metadata, pricing, and equipment mechanics.

### Public/External Functions

#### `constructor(address _coreContract, address _treasury, uint256 _initialUsdToNativeRate)`
- **Description**: Initializes the `WizverseNFT` contract.
- **Parameters**:
    - `_coreContract`: The address of the `WizverseCore` contract.
    - `_treasury`: The address for receiving payments from NFT sales.
    - `_initialUsdToNativeRate`: The initial exchange rate from USD to the native chain currency.
- **Modifiers**: `Ownable`

#### `setWizardMetadata(...)`
- **Description**: Sets the metadata for a specific wizard type.
- **Parameters**:
    - `wizardType`: The wizard type ID (0-9).
    - `title`, `description`, `animationUrl`: Metadata strings.
    - `priceModifier`: An additional price modifier in USD.
- **Modifiers**: `onlyOwner`

#### `setWeaponMetadata(...)`
- **Description**: Sets the metadata for a specific weapon type.
- **Parameters**:
    - `weaponType`: The weapon type ID (10-19).
    - ... (other params similar to `setWizardMetadata`).
- **Modifiers**: `onlyOwner`

#### `setPlatformMetadata(...)`
- **Description**: Sets the metadata for a specific platform type.
- **Parameters**:
    - `platformType`: The platform type ID (100+).
    - ... (other params similar to `setWizardMetadata`).
- **Modifiers**: `onlyOwner`

#### `getWizardMetadata(uint8 wizardType)`
- **Description**: Retrieves the metadata for a wizard type.
- **Parameters**:
    - `wizardType`: The wizard type ID.
- **Returns**:
    - `ComponentMetadata`: The metadata struct.

#### `getWeaponMetadata(uint8 weaponType)`
- **Description**: Retrieves the metadata for a weapon type.
- **Parameters**:
    - `weaponType`: The weapon type ID.
- **Returns**:
    - `ComponentMetadata`: The metadata struct.

#### `getPlatformMetadata(uint16 platformType)`
- **Description**: Retrieves the metadata for a platform type.
- **Parameters**:
    - `platformType`: The platform type ID.
- **Returns**:
    - `ComponentMetadata`: The metadata struct.

#### `getPriceUsd(uint8 wizardType, uint8 weaponType, uint16 platformType)`
- **Description**: Calculates the total price in USD for a combination of NFT components.
- **Parameters**:
    - `wizardType`, `weaponType`, `platformType`: Type IDs of the components. Use `type(uintX).max` to skip a component.
- **Returns**:
    - `uint256`: The total price in USD (with 18 decimals).

#### `getPriceNative(uint8 wizardType, uint8 weaponType, uint16 platformType)`
- **Description**: Calculates the total price in the native chain currency.
- **Parameters**:
    - `wizardType`, `weaponType`, `platformType`: Type IDs of the components.
- **Returns**:
    - `uint256`: The total price in the native currency.

#### `getPriceToken(uint8 wizardType, uint8 weaponType, uint16 platformType, address token)`
- **Description**: Calculates the total price in a specified ERC20 token.
- **Parameters**:
    - `wizardType`, `weaponType`, `platformType`: Type IDs of the components.
    - `token`: The address of the ERC20 token.
- **Returns**:
    - `uint256`: The total price in the specified token's units.

#### `equipWeapon(uint256 wizardId, uint256 weaponId)`
- **Description**: Equips a weapon NFT to a wizard NFT.
- **Parameters**:
    - `wizardId`: The token ID of the wizard.
    - `weaponId`: The token ID of the weapon.

#### `unequipWeapon(uint256 wizardId)`
- **Description**: Unequips the currently equipped weapon from a wizard.
- **Parameters**:
    - `wizardId`: The token ID of the wizard.

#### `equipPlatform(uint256 wizardId, uint256 platformId)`
- **Description**: Equips a platform NFT to a wizard NFT.
- **Parameters**:
    - `wizardId`: The token ID of the wizard.
    - `platformId`: The token ID of the platform.

#### `unequipPlatform(uint256 wizardId)`
- **Description**: Unequips the currently equipped platform from a wizard.
- **Parameters**:
    - `wizardId`: The token ID of the wizard.

#### `getWizardWithEquippedStats(uint256 tokenId)`
- **Description**: Retrieves the combined stats of a wizard, including bonuses from their equipped weapon and platform.
- **Parameters**:
    - `tokenId`: The token ID of the wizard.
- **Returns**:
    - ... (various combined stats of the wizard).

#### `getWeaponAttributes(uint256 tokenId)`
- **Description**: Retrieves the attributes of a specific weapon NFT.
- **Parameters**:
    - `tokenId`: The token ID of the weapon.
- **Returns**:
    - `WeaponAttributes`: A struct with the weapon's attributes.

#### `getPlatformAttributes(uint256 tokenId)`
- **Description**: Retrieves the attributes of a specific platform NFT.
- **Parameters**:
    - `tokenId`: The token ID of the platform.
- **Returns**:
    - `PlatformAttributes`: A struct with the platform's attributes.

#### `isWizard(uint256 tokenId)`
- **Description**: Checks if a given token ID corresponds to a wizard NFT.
- **Parameters**:
    - `tokenId`: The token ID to check.
- **Returns**:
    - `bool`: `true` if it's a wizard.

#### `isWeapon(uint256 tokenId)`
- **Description**: Checks if a given token ID corresponds to a weapon NFT.
- **Parameters**:
    - `tokenId`: The token ID to check.
- **Returns**:
    - `bool`: `true` if it's a weapon.

#### `isPlatform(uint256 tokenId)`
- **Description**: Checks if a given token ID corresponds to a platform NFT.
- **Parameters**:
    - `tokenId`: The token ID to check.
- **Returns**:
    - `bool`: `true` if it's a platform.

#### `totalWizardsMinted()`
- **Description**: Returns the total number of wizard NFTs minted.
- **Returns**:
    - `uint256`: The total count.

#### `totalWeaponsMinted()`
- **Description**: Returns the total number of weapon NFTs minted.
- **Returns**:
    - `uint256`: The total count.

#### `totalPlatformsMinted()`
- **Description**: Returns the total number of platform NFTs minted.
- **Returns**:
    - `uint256`: The total count.

#### `mintNFT(address to, uint16 nftType)`
- **Description**: Mints a new NFT of a specified type.
- **Parameters**:
    - `to`: The recipient address.
    - `nftType`: The type ID of the NFT to mint.
- **Modifiers**: `onlyOwner` or `nftManager`
- **Returns**:
    - `tokenId`: The ID of the newly minted token.

#### `batchMintNFTs(address to, uint16[] calldata nftTypes)`
- **Description**: Mints a batch of new NFTs of various types.
- **Parameters**:
    - `to`: The recipient address.
    - `nftTypes`: An array of NFT type IDs to mint.
- **Modifiers**: `onlyOwner` or `nftManager`
- **Returns**:
    - `tokenIds`: An array of the newly minted token IDs.

#### `updateWizardAttributes(...)`
- **Description**: Updates all attributes for a specific wizard.
- **Parameters**:
    - `tokenId`: The token ID of the wizard.
    - ... (various wizard attributes).
- **Modifiers**: `onlyOwner`, `coreContract`, or `nftManager`.

#### `getWizardAttributes(uint256 tokenId)`
- **Description**: Retrieves the base attributes of a specific wizard NFT.
- **Parameters**:
    - `tokenId`: The token ID of the wizard.
- **Returns**:
    - `WizardAttributes`: A struct with the wizard's attributes.

#### `updateProgress(uint256 tokenId, uint32 expGain, uint32 scoreGain)`
- **Description**: Updates a wizard's experience and score.
- **Parameters**:
    - `tokenId`: The token ID of the wizard.
    - `expGain`: Experience points to add.
    - `scoreGain`: Score to add.
- **Modifiers**: `onlyOwner` or `coreContract`.

#### `setBaseURI(string memory newBaseURI)`
- **Description**: Sets the base URI for token metadata.
- **Parameters**:
    - `newBaseURI`: The new base URI string.
- **Modifiers**: `onlyOwner`

#### `totalMinted()`
- **Description**: Returns the total number of NFTs minted so far (the next token ID).
- **Returns**:
    - `uint256`: The total count.

#### `isApprovedForAll(address owner, address operator)`
- **Description**: Overrides the standard ERC721 function to grant automatic approval to the `coreContract` and `nftManager`.
- **Parameters**:
    - `owner`: The owner of the NFTs.
    - `operator`: The address to check for approval.
- **Returns**:
    - `bool`: `true` if the operator is approved.

#### `setNFTManager(address _nftManager)`
- **Description**: Sets the address of the `WizverseNFTManager` contract.
- **Parameters**:
    - `_nftManager`: The new manager contract address.
- **Modifiers**: `onlyOwner`

#### `setBaseAttributes(...)`
- **Description**: Sets the base attributes for a specific wizard type.
- **Parameters**:
    - `wizardType`: The wizard type ID (0-9).
    - ... (various base attributes).
- **Modifiers**: `onlyOwner`

#### `tokensOfOwner(address owner)`
- **Description**: Returns an array of token IDs owned by a specific address.
- **Parameters**:
    - `owner`: The address to query.
- **Returns**:
    - `uint256[]`: An array of token IDs.

#### `setTokenExchangeRate(address token, uint256 rate)`
- **Description**: Sets the exchange rate for a supported ERC20 token against USD.
- **Parameters**:
    - `token`: The ERC20 token address.
    - `rate`: The new exchange rate (1 USD = `rate` tokens).
- **Modifiers**: `onlyOwner`

#### `batchClaim(...)`
- **Description**: Allows a user to purchase a batch of NFTs with native currency. Delegates the logic to `WizverseNFTManager`.
- **Parameters**:
    - `types`: An array of NFT type IDs to claim.
    - `referrer`: Address of the referrer for fee sharing.
    - `isPlatformDistribution`: Boolean to indicate if fees should be distributed to platforms.
- **Returns**:
    - `tokenIds`: An array of minted token IDs.

#### `batchClaimToken(...)`
- **Description**: Allows a user to purchase a batch of NFTs with an ERC20 token. Delegates to `WizverseNFTManager`.
- **Parameters**:
    - `types`: An array of NFT type IDs to claim.
    - `token`: The ERC20 token for payment.
    - `referrer`: Address of the referrer.
    - `isPlatformDistribution`: Boolean for platform fee distribution.
- **Returns**:
    - `tokenIds`: An array of minted token IDs.

#### `tokenURI(uint256 tokenId)`
- **Description**: Returns the metadata URI for a given token ID.
- **Parameters**:
    - `tokenId`: The token ID.
- **Returns**:
    - `string`: The metadata URI.

#### `setBasePriceUsd(uint256 newPriceUsd)`
- **Description**: Sets the base price in USD for minting NFTs.
- **Parameters**:
    - `newPriceUsd`: The new base price in USD.
- **Modifiers**: `onlyOwner`

#### `setWizardPriceInflation(uint256 newInflation)`
- **Description**: Sets the price inflation rate for wizards.
- **Parameters**:
    - `newInflation`: The new inflation rate (e.g., 100 = 1%).
- **Modifiers**: `onlyOwner`

#### `setWeaponPriceInflation(uint256 newInflation)`
- **Description**: Sets the price inflation rate for weapons.
- **Parameters**:
    - `newInflation`: The new inflation rate.
- **Modifiers**: `onlyOwner`

#### `setPlatformPriceInflation(uint256 newInflation)`
- **Description**: Sets the price inflation rate for platforms.
- **Parameters**:
    - `newInflation`: The new inflation rate.
- **Modifiers**: `onlyOwner`

#### `setCoreFeePercent(uint256 _percent)`
- **Description**: Sets the percentage of primary sales revenue that goes to the Core contract.
- **Parameters**:
    - `_percent`: The percentage (out of 10000).
- **Modifiers**: `onlyOwner`

#### `getRestoredHealth(uint256 tokenId)`
- **Description**: Calculates the full health value a wizard should be restored to.
- **Parameters**:
    - `tokenId`: The token ID of the wizard.
- **Returns**:
    - `uint16`: The calculated full health value.

#### `setReferrerFeePercent(uint256 _percent)`
- **Description**: Sets the percentage of primary sales revenue that goes to a referrer.
- **Parameters**:
    - `_percent`: The percentage (out of 10000).
- **Modifiers**: `onlyOwner`

#### `getNFTTypeById(uint256 tokenId)`
- **Description**: Returns the NFT type ID for a given token ID.
- **Parameters**:
    - `tokenId`: The token ID.
- **Returns**:
    - `uint16`: The NFT type ID.

#### `getBatchPriceNative(uint16[] calldata types)`
- **Description**: Calculates the total price in native currency for a batch of NFT types.
- **Parameters**:
    - `types`: An array of NFT type IDs.
- **Returns**:
    - `uint256`: The total price.

#### `getBatchPriceToken(uint16[] calldata types, address token)`
- **Description**: Calculates the total price in an ERC20 token for a batch of NFT types.
- **Parameters**:
    - `types`: An array of NFT type IDs.
    - `token`: The ERC20 token address.
- **Returns**:
    - `uint256`: The total price in the token's units.

#### `isSupportedToken(address token)`
- **Description**: Checks if an ERC20 token is supported for payments.
- **Parameters**:
    - `token`: The ERC20 token address.
- **Returns**:
    - `bool`: `true` if the token is supported.

#### `getSupportedTokens()`
- **Description**: Returns an array of all supported ERC20 token addresses.
- **Returns**:
    - `address[]`: Array of token addresses.

#### `setNativePaymentsDisabled(bool _disabled)`
- **Description**: Enables or disables native currency payments for NFT claims.
- **Parameters**:
    - `_disabled`: `true` to disable, `false` to enable.
- **Modifiers**: `onlyOwner`

## `WizverseNFTManager.sol`

This contract manages the lifecycle of NFTs within the Wizverse, particularly their deposit into and withdrawal from the `WizverseCore` contract. It handles payment processing for NFT deposits and primary sales (claims).

### Public/External Functions

#### `constructor()`
- **Description**: Initializes the `WizverseNFTManager` contract.
- **Modifiers**: `Ownable`

#### `setNFTContract(address _nftContract)`
- **Description**: Sets the address of the `WizverseNFT` contract.
- **Parameters**:
    - `_nftContract`: The new NFT contract address.
- **Modifiers**: `onlyOwner`

#### `setCore(address _core)`
- **Description**: Sets the address of the `WizverseCore` contract.
- **Parameters**:
    - `_core`: The new Core contract address.
- **Modifiers**: `onlyOwner`

#### `approveToken(address token)`
- **Description**: Approves an ERC20 token for use in deposits and payments.
- **Parameters**:
    - `token`: The ERC20 token address to approve.
- **Modifiers**: `onlyOwner`

#### `revokeToken(address token)`
- **Description**: Revokes approval for an ERC20 token.
- **Parameters**:
    - `token`: The ERC20 token address to revoke.
- **Modifiers**: `onlyOwner`

#### `addNFT(uint256 tokenId, address sender)`
- **Description**: Deposits a single NFT into the `WizverseCore` contract, paid with native currency.
- **Parameters**:
    - `tokenId`: The token ID of the NFT to deposit.
    - `sender`: The owner of the NFT.
- **Returns**:
    - `bool`: `true` on success.

#### `addNFTBatch(uint256[] calldata tokenIds, address sender)`
- **Description**: Deposits a batch of NFTs into `WizverseCore`, paid with native currency.
- **Parameters**:
    - `tokenIds`: An array of token IDs to deposit.
    - `sender`: The owner of the NFTs.
- **Returns**:
    - `bool`: `true` on success.

#### `addNFTBatchTo(...)`
- **Description**: Deposits a batch of NFTs with native currency, allocating a percentage of the fee to a specified platform via `WizverseCore`.
- **Parameters**:
    - `platformTokenId`: The platform to receive a share of the fees.
    - `tokenIds`: An array of token IDs to deposit.
    - `sender`: The owner of the NFTs.
    - `percentForPlatform`: The percentage of the fee for the platform.
- **Returns**:
    - `bool`: `true` on success.

#### `addNFTToken(...)`
- **Description**: Deposits a single NFT into `WizverseCore`, paid with an ERC20 token.
- **Parameters**:
    - `tokenId`: The token ID to deposit.
    - `paymentToken`: The ERC20 token for payment.
    - `tokenAmount`: The amount of tokens paid.
    - `sender`: The owner of the NFT.
- **Returns**:
    - `bool`: `true` on success.

#### `addNFTBatchToken(...)`
- **Description**: Deposits a batch of NFTs, paid with an ERC20 token.
- **Parameters**:
    - `tokenIds`: An array of token IDs to deposit.
    - `paymentToken`: The ERC20 token for payment.
    - `tokenAmount`: The amount paid.
    - `sender`: The owner of the NFTs.
- **Returns**:
    - `bool`: `true` on success.

#### `addNFTBatchTokenTo(...)`
- **Description**: Deposits a batch of NFTs with an ERC20 token, allocating a fee percentage to a platform.
- **Parameters**:
    - `platformTokenId`: The platform to receive a share of the fees.
    - `tokenIds`: An array of token IDs to deposit.
    - `token`: The ERC20 token for payment.
    - `tokenAmount`: The amount paid.
    - `sender`: The owner of the NFTs.
    - `percentForPlatform`: The percentage of the fee for the platform.
- **Returns**:
    - `bool`: `true` on success.

#### `returnNFT(uint256 tokenId, address sender)`
- **Description**: Verifies that a user can return a deposited NFT. This function updates the internal state; the actual transfer is done by `WizverseCore`.
- **Parameters**:
    - `tokenId`: The token ID to return.
    - `sender`: The address requesting the return (must be the original owner).
- **Returns**:
    - `bool`: `true` on success.

#### `_safelyCategorizeNFT(uint256 tokenId)`
- **Description**: An internal-facing external function to categorize a newly deposited NFT by its type.
- **Parameters**:
    - `tokenId`: The token ID to categorize.

#### `getDepositedNFTs(address wallet)`
- **Description**: Returns an array of token IDs for all NFTs deposited by a specific wallet.
- **Parameters**:
    - `wallet`: The wallet address to query.
- **Returns**:
    - `uint256[]`: An array of deposited token IDs.

#### `batchClaimNFT(...)`
- **Description**: Handles the logic for purchasing a batch of NFTs with native currency, including fee distribution and minting.
- **Parameters**:
    - `types`: An array of NFT type IDs to claim.
    - `sender`: The address purchasing the NFTs.
    - `referrer`: Address of the referrer for fee sharing.
    - `isPlatformDistribution`: Boolean for platform fee distribution.
- **Returns**:
    - `tokenIds`: An array of minted token IDs.

#### `batchClaimNFTToken(...)`
- **Description**: Handles the logic for purchasing a batch of NFTs with an ERC20 token.
- **Parameters**:
    - `types`: An array of NFT type IDs to claim.
    - `token`: The ERC20 token for payment.
    - `sender`: The address purchasing the NFTs.
    - `referrer`: Address of the referrer.
    - `isPlatformDistribution`: Boolean for platform fee distribution.
- **Returns**:
    - `tokenIds`: An array of minted token IDs.

#### `calculatePlatformType(uint8 wizardType)`
- **Description**: A pure function to determine the corresponding platform type for a given wizard type.
- **Parameters**:
    - `wizardType`: The wizard type ID (0-9).
- **Returns**:
    - `platformType`: The calculated platform type ID.

#### `getOriginalOwner(uint256 tokenId)`
- **Description**: Returns the recorded original owner of a deposited NFT.
- **Parameters**:
    - `tokenId`: The token ID to query.
- **Returns**:
    - `address`: The original owner's address.

#### `executeNativeHealthRestore(...)`
- **Description**: Executes the logic for restoring a wizard's health, paid with native currency. Called by `WizverseCore`.
- **Parameters**:
    - `tokenId`: The wizard's token ID.
    - `amountPaidByPayer`: The native currency amount paid by the user.
    - `restorationFeeUsdFromCore`: The restoration fee in USD.
- **Modifiers**: Called only by `WizverseCore`.
- **Returns**:
    - `wizardType`: The type of the restored wizard.
    - `actualFeePaid`: The fee amount transferred.

#### `executeTokenHealthRestore(...)`
- **Description**: Executes the logic for restoring a wizard's health, paid with an ERC20 token. Called by `WizverseCore`.
- **Parameters**:
    - `tokenId`: The wizard's token ID.
    - `tokenAddress`: The ERC20 token address for payment.
    - `restorationFeeUsdFromCore`: The restoration fee in USD.
    - `payer`: The address that paid for the restoration.
- **Modifiers**: Called only by `WizverseCore`.
- **Returns**:
    - `wizardType`: The type of the restored wizard.
    - `actualFeePaid`: The token amount transferred.

## `WizverseSessions.sol`

This contract manages the creation, state, and outcomes of game sessions in the Wizverse. It tracks session details, player involvement, winners, and reward distribution logic.

### Public/External Functions

#### `constructor(address _nftManager)`
- **Description**: Initializes the `WizverseSessions` contract.
- **Parameters**:
    - `_nftManager`: The address of the `WizverseNFTManager` contract.
- **Modifiers**: `Ownable`

#### `setCore(address _core)`
- **Description**: Sets the address of the `WizverseCore` contract.
- **Parameters**:
    - `_core`: The new Core contract address.
- **Modifiers**: `onlyOwner`

#### `setPercentPayWinner(uint256 _percentPayWinner)`
- **Description**: Sets the default percentage of platform assets to be paid to session winners.
- **Parameters**:
    - `_percentPayWinner`: The new percentage (out of 10000).
- **Modifiers**: `onlyOwner`

#### `checkPlatformHasActiveSessions(uint256 platformTokenId)`
- **Description**: Checks if a platform has any active sessions and returns the count.
- **Parameters**:
    - `platformTokenId`: The token ID of the platform.
- **Returns**:
    - `hasActiveSessions`: `true` if there are active sessions.
    - `activeSessionCount`: The number of active sessions.

#### `getPlatformTotalSessions(uint256 platformTokenId)`
- **Description**: Gets the total number of sessions (active and inactive) associated with a platform.
- **Parameters**:
    - `platformTokenId`: The platform token ID.
- **Returns**:
    - `totalCount`: The total number of sessions.

#### `createSessionSolo(...)`
- **Description**: Creates a new solo game session.
- **Parameters**:
    - `characterTokenId`, `weaponTokenId`, `platformTokenId`: Token IDs for the session.
    - `player`: The player's address.
- **Modifiers**: `onlyCore`
- **Returns**:
    - `sessionId`: The ID of the newly created session.

#### `createSessionTeam(...)`
- **Description**: Creates a new team-based game session.
- **Parameters**:
    - `teamCharacterTokenIds`, `teamWeaponTokenIds`: Arrays of token IDs for the team.
    - `platformTokenId`: The platform token ID.
    - `players`: An array of player addresses.
- **Modifiers**: `onlyCore`
- **Returns**:
    - `sessionId`: The ID of the newly created session.

#### `createSessionMultiplayer(...)`
- **Description**: Creates a new multiplayer game session for two teams.
- **Parameters**:
    - `team1CharacterTokenIds`, `team1WeaponTokenIds`: Token IDs for team 1.
    - `team2CharacterTokenIds`, `team2WeaponTokenIds`: Token IDs for team 2.
    - `platformTokenId`: The platform token ID.
    - `players`: An array of the two player addresses.
- **Modifiers**: `onlyCore`
- **Returns**:
    - `sessionId`: The ID of the newly created session.

#### `updateSession(...)`
- **Description**: Updates the outcome and state of a session. If the session has winners, it calculates rewards and triggers distribution via `WizverseCore`.
- **Parameters**:
    - `sessionId`: The ID of the session to update.
    - `outcome`: The outcome of the session.
    - `winnerTokenIds`: An array of token IDs for the winners.
    - `completed`: A boolean indicating if the session is completed.
- **Modifiers**: `onlyCore`

#### `createSignin(address wallet)`
- **Description**: Records a sign-in timestamp for a wallet.
- **Parameters**:
    - `wallet`: The wallet address to sign-in.
- **Modifiers**: `onlyCore`

#### `getSigninTimestamp(address wallet)`
- **Description**: Retrieves the sign-in timestamp for a given wallet.
- **Parameters**:
    - `wallet`: The wallet address.
- **Returns**:
    - `uint256`: The Unix timestamp of the sign-in.

#### `getActiveSessions(address player, uint256 offset, uint256 limit)`
- **Description**: Retrieves active game sessions for a player with pagination.
- **Parameters**:
    - `player`: The player's address (`address(0)` for all active sessions).
    - `offset`: Starting index for pagination.
    - `limit`: Maximum number of sessions to return.
- **Returns**:
    - `uint256[]`: An array of active session IDs.

#### `getSessionInfo(...)`
- **Description**: Retrieves detailed information about a specific session.
- **Parameters**:
    - `sessionId`: The ID of the session.
- **Returns**:
    - ... (various details of the session like ID, platform, timestamp, players, status).

#### `getActivePlatformSessions(...)`
- **Description**: Retrieves active sessions for a specific platform with pagination.
- **Parameters**:
    - `platformTokenId`: The platform token ID.
    - `offset`: Starting index for pagination.
    - `limit`: Maximum number of sessions.
- **Returns**:
    - `sessionIds`: An array of active session IDs.

#### `getSessionPlayers(uint256 sessionId)`
- **Description**: Retrieves the array of player addresses for a specific session.
- **Parameters**:
    - `sessionId`: The ID of the session.
- **Returns**:
    - `players`: An array of player addresses.

#### `requestToClaimRewards(address sender)`
- **Description**: Allows a user (via `WizverseCore`) to request their available rewards, adding them to a waiting list for confirmation.
- **Parameters**:
    - `sender`: The address of the user requesting to claim.
- **Modifiers**: `onlyCore`
- **Returns**:
    - `bool`: `true` on success.

#### `withdrawEther()`
- **Description**: Allows the contract owner to withdraw the entire native currency balance of the contract.
- **Modifiers**: `onlyOwner`

#### `withdrawTokens(address tokenContract, address recipient)`
- **Description**: Allows the owner to withdraw the entire balance of a specific ERC20 token.
- **Parameters**:
    - `tokenContract`: The address of the ERC20 token.
    - `recipient`: The address to receive the tokens.
- **Modifiers**: `onlyOwner`

#### `confirmClaim(address winner)`
- **Description**: Allows the owner to confirm a reward claim from the waiting list and transfer the funds to the winner.
- **Parameters**:
    - `winner`: The address of the winner whose claim is being confirmed.
- **Modifiers**: `onlyOwner`
- **Returns**:
    - `bool`: `true` on success.

#### `getWaitingWallets()`
- **Description**: Returns the array of all wallets currently on the waiting list to have their rewards confirmed.
- **Returns**:
    - `address[]`: An array of wallet addresses.

#### `getWaitingWalletsLength()`
- **Description**: Returns the number of wallets on the waiting list.
- **Returns**:
    - `uint256`: The length of the waiting list.

#### `getWaitingWallet(address wallet)`
- **Description**: Retrieves details about rewards currently in the escrow waiting for a specific wallet.
- **Parameters**:
    - `wallet`: The wallet address to query.
- **Returns**:
    - `hasWaitingRewards`: `true` if rewards are waiting.
    - `waitingRewards`: Details of the waiting rewards.
    - `platformIds`: Associated platform token IDs.

#### `canRequestRewards(address sender)`
- **Description**: Checks if a user has any unclaimed rewards from completed sessions that they are eligible to request.
- **Parameters**:
    - `sender`: The wallet address to check.
- **Returns**:
    - `canActuallyRequest`: `true` if the user has unclaimed rewards.
    - `pendingRewards`: Details of the pending rewards.

#### `getWinnerDetails(uint256 sessionId)`
- **Description**: A helper to fetch the winners' wallets and reward amounts for a session.
- **Parameters**:
    - `sessionId`: The ID of the session.
- **Returns**:
    - `wallets`: Array of winner addresses.
    - `amounts`: Array of corresponding reward amounts.

#### `getFullSessionDetails(uint256 sessionId)`
- **Description**: A helper to fetch all creation details of a session, used by `WizverseCore` for event emission.
- **Parameters**:
    - `sessionId`: The ID of the session.
- **Returns**:
    - ... (various session creation details).

