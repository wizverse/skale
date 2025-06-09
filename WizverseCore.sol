// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IWizverseNFT.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./interfaces/IWizverseSessions.sol";
import "./interfaces/IWizverseNFTManager.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract WizverseCore is Ownable {
    using ECDSA for bytes32;
    using Address for address payable;
    using Strings for uint256;
    
    // Delegated module addresses.
    address public sessions;
    address public nftManager;
    
    // Global addresses.
    address public treasury;
    address public backendSigner;
    address public nftContract; // Used for token payment functions

    // Minimum fee in USD (with 18 decimals)
    uint256 public minFeeUsd;
    event MinFeeUsdUpdated(uint256 previousMinFee, uint256 newMinFee);
    
    // Other events...
    event TreasuryUpdated(address previousTreasury, address newTreasury);
    event NFTContractUpdated(address previousNFT, address newNFT);
    event PaymentReceived(address indexed from, uint256 amount);
    event TokenPaymentReceived(address indexed from, address indexed token, uint256 amount);
    event MagicBoxClaimed(address indexed claimer, uint256 amount);
    event PlatformAssetsUpdated(uint256 indexed platformTokenId, uint256 amount, address token);
    event PercentFeesLeavedForPlayersUpdated(uint256 oldPercent, uint256 newPercent);
    event PlatformFeesDistributed(uint256 totalAmount, address token, uint256 platformCount);
    event HealthRestored(uint256 indexed tokenId, uint8 wizardType, uint256 feeAmount, address indexed tokenAddress, address indexed payer);
    // Removed redundant events for session tracking

    // Event for session creation, now emitted by Core
    event SessionCreated(
        uint256 indexed sessionId,
        SessionType sessionType,
        uint256 indexed platformTokenId,
        address[] players,
        uint256[][] teamCharacterTokenIds,
        uint256[][] teamWeaponTokenIds,
        uint256 timestamp
    );

    // Mirror of the Sessions contract event so indexers can listen only to Core if desired
    event SessionUpdated(
        uint256 indexed sessionId,
        uint8 outcome,
        uint256[] winnerTokenIds,
        bool completed,
        address[] winnersWallets,
        uint256[] winnerAmounts
    );

    // Percentage of fees that should be left for platform owners (out of 10000)
    uint256 public percentFeesLeavedForPlayers = 1000; // Default 10%

    // NEW: Percentage of platform's share that goes directly to platform owner's wallet
    uint256 public platformOwnerIncomePercent = 1000; // Default 10%
    event PlatformOwnerIncomePercentUpdated(uint256 oldPercent, uint256 newPercent);
    event PlatformOwnerPayout(uint256 indexed platformTokenId, address indexed owner, uint256 amount, address token);

    // Fee in USD for restoring health (with 18 decimals)
    uint256 public restorationFeeUsd = 1000000000000000000; // 1 USD

    // Mapping of platform token ID => native currency balance
    mapping(uint256 => uint256) public platformNativeAssets;
    
    // Mapping of platform token ID => token address => token balance
    mapping(uint256 => mapping(address => uint256)) public platformTokenAssets;
    
    // Mapping to track platforms with assets
    mapping(uint256 => bool) public hasPlatformAssets;
    
    // Counter for platform distribution
    uint256 public platformCount;
    
    // Mapping of platform token ID => total deposited assets (in native currency)
    mapping(uint256 => uint256) public platformTotalDeposited;
    
    // --- Re-added PlatformStats struct ---
    struct PlatformStats {
        uint256 platformTokenId;
        uint256 totalDeposited;      // Total native amount ever deposited to this platform via addNFTBatchTo
        uint256 totalSessions;       // Total number of sessions created with this platform (from Sessions contract)
        uint256 activeSessionsCount; // Current number of active sessions (from Sessions contract)
        address[] activePlayerWallets; // Array of unique player wallets in active sessions (from Sessions contract)
        uint256[] activeSessions;    // Array of active session IDs (from Sessions contract)
        uint256 currentNativeAssets;  // Current amount of native assets held for this platform
    }

    // --- Struct for holding all possible NFT attributes ---
    struct NFTAttributesAll {
        // Wizard Specific
        uint16 wiz_hp;
        uint16 wiz_atk;
        uint16 wiz_def;
        uint16 wiz_spd;
        uint32 wiz_exp;
        uint32 wiz_score;
        uint16 wiz_hpRe;
        uint16 wiz_hpLe;
        uint16 wiz_respawnCount;
        uint8  wiz_wizardType; // Specific wizard type (e.g., 0-4)

        // Weapon Specific
        uint16 wep_atkBonus;
        uint16 wep_defBonus;
        uint16 wep_spdBonus;
        uint8  wep_weaponType; // Specific weapon type (e.g., 10-12)
        bool   wep_isEquipped;
        uint256 wep_equippedTo;

        // Platform Specific
        uint16 plat_hpBonus;
        uint16 plat_hpReBonus;
        uint16 plat_defBonus;
        uint16 plat_hpLeBonus;
        uint16 plat_spdBonus;
        uint16 plat_atkBonus;
        uint16 plat_platformType; // Specific platform type (e.g., 100-102)
        bool   plat_isEquipped;
        uint256 plat_equippedTo;
    }
    
    // --- NFT Data Struct ---
    struct NFTData {
        uint256 tokenId;
        uint16 nftType; // General NFT type (e.g. 0 for wizard, 10 for weapon, 100 for platform)
        bool deposited;
        NFTAttributesAll attributes; // Detailed attributes based on nftType
    }
    
    // --- Struct for returning detailed platform info ---
    struct PlatformInfo {
        uint256 tokenId;
        uint16 nftType; // Platform type (100-102)
        address originalOwner; // Original owner field
        uint256 nativeBalance; // Current native currency balance
        uint256 nativeBalanceUSD; // Current native currency balance in USD
        address[] tokenAddresses; // Supported token addresses with non-zero balance
        uint256[] tokenBalances; // Corresponding token balances
        // Platform stats
        uint256 totalDeposited; // Total native amount ever deposited
        uint256 totalSessions; // Total number of sessions created with this platform
        uint256 activeSessionsCount; // Current number of active sessions
        address[] activePlayerWallets; // Array of unique player wallets in active sessions
        uint256[] activeSessions; // Array of active session IDs
    }
    
    // -------- Custom Errors (save byte-code vs. require strings) -------- //
    error SessionsNotSet();
    error NFTContractNotSet();
    error NFTManagerNotSet();
    error NotGameServer();
    // Additional custom errors
    error ExpectedTwoCharacterTeams();
    error ExpectedTwoWeaponTeams();
    error TreasuryCannotBeZero();
    error BackendSignerCannotBeZero();
    error SessionsModuleNotSet();
    error NFTManagerModuleNotSet();
    error CallerNotAuthorized();
    error PercentageMustBeLessThanOrEqual10000();
    error NFTContractCannotBeZero();
    error NativePaymentIsDisabled();
    error OnlyNFTManagerCanUpdatePlatformAssets();
    error InsufficientPayment();
    error FailedToForwardFunds();
    error InsufficientTokenPayment();
    error UnsupportedToken();
    error TokenTransferFailed();
    error PlatformHasNoAssets();
    error TokenNotDeposited(uint256 tokenId);
    error NoNativeBalanceToWithdraw();
    error NoTokenBalanceToWithdraw();
    error RecipientCannotBeZeroAddress();
    error ManagerVerificationFailed();
    error InsufficientPlatformAssets();
    error ETHTransferZeroNotAllowed();
    error ETHTransferToSessionsFailed();
    error NoWinnersProvided();
    error WinnersAndAmountsLengthMismatch();
    error RestorationFeeNotSetOrZero();
    error NFTTreasuryNotSet();
    // New error for platform owner token transfers
    error TokenTransferToOwnerFailed();
    // ------------------------------------------------------------------- //

    bool public nativePaymentsDisabled;
    event NativePaymentsDisabledSet(bool disabled);

    // --- Constructor ---
    constructor(
        address initialOwner, 
        address _treasury, 
        address _backendSigner,
        address _sessions,
        address _nftManager
    ) Ownable(initialOwner) {
        if (_treasury == address(0)) revert TreasuryCannotBeZero();
        if (_backendSigner == address(0)) revert BackendSignerCannotBeZero();
        if (_sessions == address(0)) revert SessionsModuleNotSet();
        if (_nftManager == address(0)) revert NFTManagerModuleNotSet();
        
        treasury = _treasury;
        backendSigner = _backendSigner;
        sessions = _sessions;
        nftManager = _nftManager;

        // Set initialOwner as a game server.
        isGameServer[initialOwner] = true;
    }
    
    // -- Administrative functions --
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert TreasuryCannotBeZero();
        address previousTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(previousTreasury, _treasury);
    }
    
    function setNFTContract(address _nftContract) external onlyOwner {
        if (_nftContract == address(0)) revert NFTContractCannotBeZero();
        address previousNFT = nftContract;
        nftContract = _nftContract;
        emit NFTContractUpdated(previousNFT, _nftContract);
    }
    
    function setMinFeeUsd(uint256 _fee) external onlyOwner {
        uint256 previous = minFeeUsd;
        minFeeUsd = _fee;
        emit MinFeeUsdUpdated(previous, _fee);
    }
    
    /**
     * @dev Sets the fee in USD for health restoration.
     * @param _newFee The new fee in USD (with 18 decimals).
     */
    function setRestorationFeeUsd(uint256 _newFee) external onlyOwner {
        // require(_newFee > 0, "WizverseCore: Restoration fee must be positive"); // Allow 0 for free restoration if desired
        restorationFeeUsd = _newFee;
        // Optionally emit an event: FeeUpdated("RestorationFeeUSD", _newFee);
    }
    
    /**
     * @dev Sets the percentage of fees left for platform owners.
     * @param _percent New percentage (out of 10000)
     */
    function setPercentFeesLeavedForPlayers(uint256 _percent) external {
        if (!isGameServer[msg.sender] && owner() != msg.sender) revert CallerNotAuthorized();
        if (_percent > 10000) revert PercentageMustBeLessThanOrEqual10000();
        uint256 oldPercent = percentFeesLeavedForPlayers;
        percentFeesLeavedForPlayers = _percent;
        emit PercentFeesLeavedForPlayersUpdated(oldPercent, _percent);
    }
    
    /**
     * @dev Sets the percentage of platform income that goes directly to the platform owner.
     * @param _percent New percentage (out of 10000)
     */
    function setPlatformOwnerIncomePercent(uint256 _percent) external onlyOwner {
        if (_percent > 10000) revert PercentageMustBeLessThanOrEqual10000();
        uint256 oldPercent = platformOwnerIncomePercent;
        platformOwnerIncomePercent = _percent;
        emit PlatformOwnerIncomePercentUpdated(oldPercent, _percent);
    }
    
    /**
     * @dev Update the assets allocated to a platform
     * @param platformTokenId The platform token ID
     * @param amount The amount to add
     * @param token The token address (use address(0) for native currency)
     */
    function updatePlatformAssets(uint256 platformTokenId, uint256 amount, address token) external {
        if (msg.sender != nftManager) revert OnlyNFTManagerCanUpdatePlatformAssets();
        if (nftContract == address(0)) revert NFTContractNotSet();
        if (nftManager == address(0)) revert NFTManagerNotSet(); // Ensure NFT Manager is set for getOriginalOwner

        address originalOwner = IWizverseNFTManager(nftManager).getOriginalOwner(platformTokenId);
        uint256 ownerShare = 0;
        uint256 platformShare = amount;

        if (originalOwner != address(0) && platformOwnerIncomePercent > 0 && amount > 0) {
            ownerShare = (amount * platformOwnerIncomePercent) / 10000;
            platformShare = amount - ownerShare;

            if (ownerShare > 0) {
                if (token == address(0)) {
                    // Native currency payout to owner
                    payable(originalOwner).sendValue(ownerShare);
                } else {
                    // ERC20 token payout to owner
                    // Ensure this contract (WizverseCore) has the tokens to send.
                    // This implies WizverseNFTManager transferred the full 'amount' of tokens to WizverseCore.
                    bool success = IERC20(token).transfer(originalOwner, ownerShare);
                    if (!success) revert TokenTransferToOwnerFailed();
                }
                emit PlatformOwnerPayout(platformTokenId, originalOwner, ownerShare, token);
            }
        }
        
        // Mark platform as having assets if not already (based on platformShare)
        if (platformShare > 0 && !hasPlatformAssets[platformTokenId]) {
            hasPlatformAssets[platformTokenId] = true;
            platformCount++;
        }
        
        // Update the appropriate asset balance with platformShare
        if (token == address(0)) {
            // Native currency
            if (platformShare > 0) {
                platformNativeAssets[platformTokenId] += platformShare;
            }
            // Update total deposited for this platform (based on what stays with the platform)
            // This previously added the full 'amount'. Now it should add 'platformShare'.
            // Or, if platformTotalDeposited is meant to track ALL funds ever directed at the platform (before owner payout),
            // then it should still be `amount`. For now, assuming it tracks funds available to the platform.
            platformTotalDeposited[platformTokenId] += platformShare; 
        } else {
            // ERC20 token
            require(IWizverseNFT(nftContract).isSupportedToken(token), "WizverseCore: unsupported token");
            if (platformShare > 0) {
                platformTokenAssets[platformTokenId][token] += platformShare;
            }
        }
        
        // Emit event for the assets actually updated on the platform
        if (platformShare > 0) {
            emit PlatformAssetsUpdated(platformTokenId, platformShare, token);
        }
    }
    
    /**
     * @dev Distribute fee to a single platform
     * @param platformTokenId The platform token ID to receive the fee
     * @param amount The amount to distribute
     * @param token The token address (address(0) for native currency)
     */
    function distributePlatformFee(uint256 platformTokenId, uint256 amount, address token) external {
        if (!isGameServer[msg.sender] && owner() != msg.sender) revert CallerNotAuthorized();
        if (!hasPlatformAssets[platformTokenId]) {
            hasPlatformAssets[platformTokenId] = true;
            platformCount++;
        }
        
        if (token == address(0)) {
            // Native currency distribution
            platformNativeAssets[platformTokenId] += amount;
        } else {
            // ERC20 token distribution
            if (nftContract == address(0)) revert NFTContractNotSet();
            if (!IWizverseNFT(nftContract).isSupportedToken(token)) revert UnsupportedToken();
            platformTokenAssets[platformTokenId][token] += amount;
        }
        
        emit PlatformAssetsUpdated(platformTokenId, amount, token);
    }
    
    /**
     * @dev Get the assets for a specific platform
     * @param platformTokenId The platform token ID
     * @return native Native currency balance
     * @return tokens Array of token addresses
     * @return balances Array of token balances
     */
    function getPlatformAssets(uint256 platformTokenId) external view returns (
        uint256 native,
        address[] memory tokens,
        uint256[] memory balances
    ) {
        require(nftContract != address(0), "WizverseCore: NFT contract not set");
        native = platformNativeAssets[platformTokenId];
        
        // Get supported tokens from NFT contract
        address[] memory _supportedTokens = IWizverseNFT(nftContract).getSupportedTokens();
        
        // Get token balances for supported tokens
        uint256 tokenCount = 0;
        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            if (platformTokenAssets[platformTokenId][_supportedTokens[i]] > 0) {
                tokenCount++;
            }
        }
        
        tokens = new address[](tokenCount);
        balances = new uint256[](tokenCount);
        
        uint256 j = 0;
        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            address _token = _supportedTokens[i];
            uint256 balance = platformTokenAssets[platformTokenId][_token];
            if (balance > 0) {
                tokens[j] = _token;
                balances[j] = balance;
                j++;
            }
        }
        
        return (native, tokens, balances);
    }
    
    /**
     * @dev Check if a platform has assets
     * @param platformTokenId The platform token ID to check
     * @return hasAssets True if the platform has assets
     */
    function checkPlatformHasAssets(uint256 platformTokenId) external view returns (bool) {
        return hasPlatformAssets[platformTokenId];
    }
    
    /**
     * @dev Get count of platforms with assets
     * @return count Number of platforms with assets
     */
    function getPlatformCount() external view returns (uint256) {
        return platformCount;
    }
    
    function payForOperation(bytes4 /*_operation*/) external payable returns (bool) {
        if (nativePaymentsDisabled) revert NativePaymentIsDisabled();
        if (msg.value <= 0) revert InsufficientPayment();
        (bool sent, ) = treasury.call{value: msg.value}("");
        if (!sent) revert FailedToForwardFunds();
        emit PaymentReceived(msg.sender, msg.value);
        return true;
    }
    
    function payForOperationWithToken(bytes4 /*_operation*/, address _token, uint256 _amount) external returns (bool) {
        if (_amount <= 0) revert InsufficientTokenPayment();
        if (nftContract == address(0)) revert NFTContractNotSet();
        if (!IWizverseNFT(nftContract).isSupportedToken(_token)) revert UnsupportedToken();
        IERC20 tokenInstance = IERC20(_token);
        if (!tokenInstance.transferFrom(msg.sender, treasury, _amount)) revert TokenTransferFailed();
        emit TokenPaymentReceived(msg.sender, _token, _amount);
        return true;
    }
    
    // --- Delegated Session Functions ---
    function createSessionSolo(
        uint256 characterTokenId,
        uint256 weaponTokenId,
        uint256 platformTokenId,
        address player
    ) external onlyGameServer returns (uint256 sessionId) {
        _validateOwnershipSolo(characterTokenId, weaponTokenId, platformTokenId);
        // Delegate creation to WizverseSessions (assumes duplicate check happens there)
        sessionId = IWizverseSessions(sessions).createSessionSolo(
            characterTokenId,
            weaponTokenId,
            platformTokenId,
            player
        );

        // Event emission removed per optimization request

        return sessionId;
    }
    
    function createSessionTeam(
        uint256[] calldata teamCharacterTokenIds,
        uint256[] calldata teamWeaponTokenIds,
        uint256 platformTokenId,
        address[] calldata players
    ) external onlyGameServer returns (uint256 sessionId) {
        _validateOwnershipTeam(teamCharacterTokenIds, teamWeaponTokenIds, platformTokenId);
        // Delegate creation to WizverseSessions (assumes duplicate check happens there)
        sessionId = IWizverseSessions(sessions).createSessionTeam(
            teamCharacterTokenIds,
            teamWeaponTokenIds,
            platformTokenId,
            players
        );

        // Event emission removed per optimization request

        return sessionId;
    }
    
    function createSessionMultiplayer(
        uint256[][] calldata teamCharacterTokenIds, // Should be two teams [team1_chars, team2_chars]
        uint256[][] calldata teamWeaponTokenIds,    // Should be two teams [team1_weapons, team2_weapons]
        uint256 platformTokenId,
        address[] calldata players
    ) external onlyGameServer returns (uint256 sessionId) {
        // Basic validation for the input structure
        if (teamCharacterTokenIds.length != 2) revert ExpectedTwoCharacterTeams();
        if (teamWeaponTokenIds.length != 2) revert ExpectedTwoWeaponTeams();
        
        // Validate ownership first (using the correct arrays)
        _validateOwnershipMultiplayer(teamCharacterTokenIds[0], teamWeaponTokenIds[0], teamCharacterTokenIds[1], teamWeaponTokenIds[1], platformTokenId);
        
        // Delegate creation to WizverseSessions with the correct 6 arguments
        sessionId = IWizverseSessions(sessions).createSessionMultiplayer(
            teamCharacterTokenIds[0], // team 1 chars
            teamWeaponTokenIds[0],    // team 1 weapons
            teamCharacterTokenIds[1], // team 2 chars
            teamWeaponTokenIds[1],    // team 2 weapons
            platformTokenId,
            players
        );

        // Event emission removed per optimization request

        return sessionId;
    }
    
    function updateSession(uint256 sessionId, uint8 outcome, uint256[] calldata winnerTokenIds, bool completed) external onlyGameServer {
        // Delegate update to WizverseSessions
        IWizverseSessions(sessions).updateSession(sessionId, outcome, winnerTokenIds, completed);

        // Fetch winners data to include full details in Core event
        (address[] memory wallets, uint256[] memory amounts) = IWizverseSessions(sessions).getWinnerDetails(sessionId);
        emit SessionUpdated(sessionId, outcome, winnerTokenIds, completed, wallets, amounts);
    }
    
    // --- Delegated NFT Management Functions ---
 
    
    /**
     * @dev Deposit a batch of NFTs with native currency, allocating a percentage to a platform.
     * @param platformTokenId The platform token ID to allocate fees to
     * @param tokenIds Array of token IDs to deposit
     */
    function addNFTBatchTo(
        uint256 platformTokenId,
        uint256[] calldata tokenIds
    ) external payable returns (bool) {
        if (nativePaymentsDisabled) revert NativePaymentIsDisabled();
        uint256 percent = percentFeesLeavedForPlayers;
        return IWizverseNFTManager(nftManager).addNFTBatchTo{value: msg.value}(
            platformTokenId,
            tokenIds, 
            msg.sender,
            percent
        );
    }
    
    /**
     * @dev Deposit a batch of NFTs using an ERC20 token, allocating a percentage to a platform.
     * @param platformTokenId The platform token ID to allocate fees to
     * @param tokenIds Array of token IDs to deposit
     * @param token ERC20 token address
     * @param tokenAmount Amount of tokens to pay
     */
    function addNFTBatchTokenTo(
        uint256 platformTokenId,
        uint256[] calldata tokenIds,
        address token,
        uint256 tokenAmount
    ) external returns (bool) {
        uint256 percent = percentFeesLeavedForPlayers;
        return IWizverseNFTManager(nftManager).addNFTBatchTokenTo(
            platformTokenId,
            tokenIds,
            token,
            tokenAmount,
            msg.sender,
            percent
        );
    }
    
    function returnNFT(uint256 tokenId) external returns (bool) {
        // Call manager to verify ownership and update its state
        bool success = IWizverseNFTManager(nftManager).returnNFT(tokenId, msg.sender);
        if (!success) revert ManagerVerificationFailed();

        // Perform the actual transfer from Core to the original owner (msg.sender)
        IERC721(nftContract).transferFrom(address(this), msg.sender, tokenId);

        return true;
    }
    
    function claimMagicBox() external {
        emit MagicBoxClaimed(msg.sender, 0);
    }
    
    function claimMagicBoxPayable() external payable {
        Address.sendValue(payable(msg.sender), msg.value);
        emit MagicBoxClaimed(msg.sender, msg.value);
    }
    
    receive() external payable {
        emit PaymentReceived(msg.sender, msg.value);
    }
    
    // --- Game Server Access Control ---
    mapping(address => bool) public isGameServer;
    modifier onlyGameServer() {
        if (!isGameServer[msg.sender]) revert NotGameServer();
        _;
    }

    // --- internal helpers to avoid repeating the same require strings --- //
    function _requireSessionsSet() internal view {
        if (sessions == address(0)) revert SessionsNotSet();
    }

    function _requireNFTContractSet() internal view {
        if (nftContract == address(0)) revert NFTContractNotSet();
    }

    // --- New Function: Set Game Servers (onlyOwner) ---
    function setGameServers(address[] calldata _gameServers) external onlyOwner {
        for(uint256 i = 0; i < _gameServers.length; i++){
            isGameServer[_gameServers[i]] = true;
        }
    }
    
    function setNativePaymentsDisabled(bool _disabled) external onlyOwner {
        nativePaymentsDisabled = _disabled;
        emit NativePaymentsDisabledSet(_disabled);
    }
    
    // --- New Function: Get NFTs by Wallet ---
    /**
     * @dev Returns an array of NFTData for a given wallet.
     * This includes NFTs deposited via the manager and NFTs still held in the wallet.
     * Note: This function relies on IWizverseNFTManager.getDepositedNFTs and IWizverseNFT.tokensOfOwner.
     */
    function getNFTsByWallet(address wallet) external view returns (NFTData[] memory nfts) {
        // Get deposited NFTs from the NFT manager.
        uint256[] memory deposited = IWizverseNFTManager(nftManager).getDepositedNFTs(wallet);
        // Get NFTs held by the wallet from the NFT contract using IERC721Enumerable functions.
        uint256 balance = IERC721Enumerable(nftContract).balanceOf(wallet);
        uint256[] memory walletTokens = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            walletTokens[i] = IERC721Enumerable(nftContract).tokenOfOwnerByIndex(wallet, i);
        }
        
        uint256 total = deposited.length + walletTokens.length;
        nfts = new NFTData[](total);
        uint256 k = 0;
        
        IWizverseNFT nft = IWizverseNFT(nftContract);

        for (uint256 i = 0; i < deposited.length; i++) {
            uint256 tokenId = deposited[i];
            uint16 nftType = _getNFTType(tokenId);
            NFTAttributesAll memory attrs = NFTAttributesAll({
                wiz_hp: 0, wiz_atk: 0, wiz_def: 0, wiz_spd: 0, wiz_exp: 0, wiz_score: 0, wiz_hpRe: 0, wiz_hpLe: 0, wiz_respawnCount: 0, wiz_wizardType: 0,
                wep_atkBonus: 0, wep_defBonus: 0, wep_spdBonus: 0, wep_weaponType: 0, wep_isEquipped: false, wep_equippedTo: 0,
                plat_hpBonus: 0, plat_hpReBonus: 0, plat_defBonus: 0, plat_hpLeBonus: 0, plat_spdBonus: 0, plat_atkBonus: 0, plat_platformType: 0, plat_isEquipped: false, plat_equippedTo: 0
            });

            if (nftType <= 9) { // Wizard
                WizardAttributes memory wizAttrs = nft.getWizardAttributes(tokenId);
                attrs.wiz_hp = wizAttrs.hp;
                attrs.wiz_atk = wizAttrs.atk;
                attrs.wiz_def = wizAttrs.def;
                attrs.wiz_spd = wizAttrs.spd;
                attrs.wiz_exp = wizAttrs.exp;
                attrs.wiz_score = wizAttrs.score;
                attrs.wiz_hpRe = wizAttrs.hpRe;
                attrs.wiz_hpLe = wizAttrs.hpLe;
                attrs.wiz_respawnCount = wizAttrs.respawnCount;
                attrs.wiz_wizardType = wizAttrs.wizardType;
            } else if (nftType >= 10 && nftType <= 19) { // Weapon
                WeaponAttributes memory wepAttrs = nft.getWeaponAttributes(tokenId);
                attrs.wep_atkBonus = wepAttrs.atkBonus;
                attrs.wep_defBonus = wepAttrs.defBonus;
                attrs.wep_spdBonus = wepAttrs.spdBonus;
                attrs.wep_weaponType = wepAttrs.weaponType;
                attrs.wep_isEquipped = wepAttrs.isEquipped;
                attrs.wep_equippedTo = wepAttrs.equippedTo;
            } else if (nftType >= 100) { // Platform
                PlatformAttributes memory platAttrs = nft.getPlatformAttributes(tokenId);
                attrs.plat_hpBonus = platAttrs.hpBonus;
                attrs.plat_hpReBonus = platAttrs.hpReBonus;
                attrs.plat_defBonus = platAttrs.defBonus;
                attrs.plat_hpLeBonus = platAttrs.hpLeBonus;
                attrs.plat_spdBonus = platAttrs.spdBonus;
                attrs.plat_atkBonus = platAttrs.atkBonus;
                attrs.plat_platformType = platAttrs.platformType;
                attrs.plat_isEquipped = platAttrs.isEquipped;
                attrs.plat_equippedTo = platAttrs.equippedTo;
            }

            nfts[k++] = NFTData({
                tokenId: tokenId,
                nftType: nftType,
                deposited: true,
                attributes: attrs
            });
        }
        for (uint256 i = 0; i < walletTokens.length; i++) {
            uint256 tokenId = walletTokens[i];
            uint16 nftType = _getNFTType(tokenId);
            NFTAttributesAll memory attrs = NFTAttributesAll({
                wiz_hp: 0, wiz_atk: 0, wiz_def: 0, wiz_spd: 0, wiz_exp: 0, wiz_score: 0, wiz_hpRe: 0, wiz_hpLe: 0, wiz_respawnCount: 0, wiz_wizardType: 0,
                wep_atkBonus: 0, wep_defBonus: 0, wep_spdBonus: 0, wep_weaponType: 0, wep_isEquipped: false, wep_equippedTo: 0,
                plat_hpBonus: 0, plat_hpReBonus: 0, plat_defBonus: 0, plat_hpLeBonus: 0, plat_spdBonus: 0, plat_atkBonus: 0, plat_platformType: 0, plat_isEquipped: false, plat_equippedTo: 0
            });

            if (nftType <= 9) { // Wizard
                WizardAttributes memory wizAttrs = nft.getWizardAttributes(tokenId);
                attrs.wiz_hp = wizAttrs.hp;
                attrs.wiz_atk = wizAttrs.atk;
                attrs.wiz_def = wizAttrs.def;
                attrs.wiz_spd = wizAttrs.spd;
                attrs.wiz_exp = wizAttrs.exp;
                attrs.wiz_score = wizAttrs.score;
                attrs.wiz_hpRe = wizAttrs.hpRe;
                attrs.wiz_hpLe = wizAttrs.hpLe;
                attrs.wiz_respawnCount = wizAttrs.respawnCount;
                attrs.wiz_wizardType = wizAttrs.wizardType;
            } else if (nftType >= 10 && nftType <= 19) { // Weapon
                WeaponAttributes memory wepAttrs = nft.getWeaponAttributes(tokenId);
                attrs.wep_atkBonus = wepAttrs.atkBonus;
                attrs.wep_defBonus = wepAttrs.defBonus;
                attrs.wep_spdBonus = wepAttrs.spdBonus;
                attrs.wep_weaponType = wepAttrs.weaponType;
                attrs.wep_isEquipped = wepAttrs.isEquipped;
                attrs.wep_equippedTo = wepAttrs.equippedTo;
            } else if (nftType >= 100) { // Platform
                PlatformAttributes memory platAttrs = nft.getPlatformAttributes(tokenId);
                attrs.plat_hpBonus = platAttrs.hpBonus;
                attrs.plat_hpReBonus = platAttrs.hpReBonus;
                attrs.plat_defBonus = platAttrs.defBonus;
                attrs.plat_hpLeBonus = platAttrs.hpLeBonus;
                attrs.plat_spdBonus = platAttrs.spdBonus;
                attrs.plat_atkBonus = platAttrs.atkBonus;
                attrs.plat_platformType = platAttrs.platformType;
                attrs.plat_isEquipped = platAttrs.isEquipped;
                attrs.plat_equippedTo = platAttrs.equippedTo;
            }
            
            nfts[k++] = NFTData({
                tokenId: walletTokens[i],
                nftType: nftType,
                deposited: false,
                attributes: attrs
            });
        }
    }
    
    /**
     * @dev Returns a simple array of tokenIds for all NFTs associated with a given wallet.
     * This includes NFTs deposited via the manager and NFTs still held in the wallet.
     * @param wallet The address to query NFTs for.
     * @return tokenIds An array of token IDs.
     */
    function getNFTsByWalletSimpleDeposited(address wallet) external view returns (uint256[] memory tokenIds) {
        // Get deposited NFTs from the NFT manager.
        uint256[] memory deposited = IWizverseNFTManager(nftManager).getDepositedNFTs(wallet);
        
        return deposited;
    }
    
    /**
     * @dev Internal function to determine the NFT type ID for a given tokenId.
     * It calls the corresponding function on the NFT contract.
     * Returns 0 if the type cannot be determined or the token doesn't exist.
     */
    function _getNFTType(uint256 tokenId) internal view returns (uint16) {
        IWizverseNFT nft = IWizverseNFT(nftContract);
        // Use the new interface function
        try nft.getNFTTypeById(tokenId) returns (uint16 typeId) {
            return typeId;
        } catch {
            return 0; // Return 0 for unknown or error
        }
    }
    
    /**
     * @dev Internal helper to check NFT ownership.
     * Requires that the NFT for a given tokenId is owned by the WizverseCore contract.
     */
    function _checkNFTOwnership(uint256 tokenId) internal view {
        if (IERC721(nftContract).ownerOf(tokenId) != address(this)) {
            revert TokenNotDeposited(tokenId);
        }
    }
    
    /**
     * @dev Validate ownership for a solo session.
     * Checks that the character, weapon and platform tokens are held by Core.
     */
    function _validateOwnershipSolo(
        uint256 characterTokenId,
        uint256 weaponTokenId,
        uint256 platformTokenId
    ) internal view {
        _checkNFTOwnership(characterTokenId);
        _checkNFTOwnership(weaponTokenId);
        _checkNFTOwnership(platformTokenId);
    }
    
    /**
     * @dev Validate ownership for a team session.
     * Iterates through the provided arrays and checks each token is deposited in Core.
     */
    function _validateOwnershipTeam(
        uint256[] calldata teamCharacterTokenIds,
        uint256[] calldata teamWeaponTokenIds,
        uint256 platformTokenId
    ) internal view {
        for (uint256 i = 0; i < teamCharacterTokenIds.length; i++) {
            _checkNFTOwnership(teamCharacterTokenIds[i]);
        }
        for (uint256 i = 0; i < teamWeaponTokenIds.length; i++) {
            _checkNFTOwnership(teamWeaponTokenIds[i]);
        }
        _checkNFTOwnership(platformTokenId);
    }
    
    /**
     * @dev Validate ownership for a multiplayer session (using two teams).
     * For simplicity, the tokens from both teams are checked to be held by Core.
     */
    function _validateOwnershipMultiplayer(
        uint256[] calldata team1CharacterTokenIds,
        uint256[] calldata team1WeaponTokenIds,
        uint256[] calldata team2CharacterTokenIds,
        uint256[] calldata team2WeaponTokenIds,
        uint256 platformTokenId
    ) internal view {
        // Check team 1 tokens.
        for (uint256 i = 0; i < team1CharacterTokenIds.length; i++) {
            _checkNFTOwnership(team1CharacterTokenIds[i]);
        }
        for (uint256 i = 0; i < team1WeaponTokenIds.length; i++) {
            _checkNFTOwnership(team1WeaponTokenIds[i]);
        }
        // Check team 2 tokens.
        for (uint256 i = 0; i < team2CharacterTokenIds.length; i++) {
            _checkNFTOwnership(team2CharacterTokenIds[i]);
        }
        for (uint256 i = 0; i < team2WeaponTokenIds.length; i++) {
            _checkNFTOwnership(team2WeaponTokenIds[i]);
        }
        _checkNFTOwnership(platformTokenId);
    }

    // Optionally, add helper functions to call signink via sessions:
    function createSignin(address wallet) external onlyGameServer {
        IWizverseSessions(sessions).createSignin(wallet);
    }
    
    function getSigninTimestamp(address wallet) external view returns (uint256) {
        return IWizverseSessions(sessions).getSigninTimestamp(wallet);
    }
    
    /**
     * @dev Update wizard attributes via the NFT contract. Can only be called by a game server.
     * @param tokenId The token ID of the wizard
     * @param hp New health points
     * @param atk New attack power
     * @param def New defense
     * @param spd New speed
     * @param exp New experience points
     * @param score New score
     * @param hpRe New health regeneration
     * @param hpLe New life endurance
     * @param respawnCount New respawn count
     */
    function updateWizardAttributesCore(
        uint256 tokenId, 
        uint16 hp,
        uint16 atk,
        uint16 def,
        uint16 spd,
        uint32 exp,
        uint32 score,
        uint16 hpRe,
        uint16 hpLe,
        uint16 respawnCount
    ) external onlyGameServer {
        require(nftContract != address(0), "WizverseCore: NFT contract not set");
        IWizverseNFT(nftContract).updateWizardAttributes(tokenId, hp, atk, def, spd, exp, score, hpRe, hpLe, respawnCount);
    }
    
    /**
     * @dev Get active game sessions for a player.
     * @param player The address of the player. Use address(0) to get all active sessions.
     * @param offset Starting index for pagination.
     * @param limit Maximum number of sessions to return.
     * @return sessionIds An array of active session IDs.
     */
    function getActiveSessions(address player, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return IWizverseSessions(sessions).getActiveSessions(player, offset, limit);
    }

    // --- Withdrawal Functions ---

    /**
     * @dev Allows the owner to withdraw the entire native coin balance of the contract.
     * Sends the balance to the owner's address.
     */
    function withdrawEther() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance <= 0) revert NoNativeBalanceToWithdraw();
        payable(owner()).sendValue(balance); // Send to owner
    }

    /**
     * @dev Allows the owner to withdraw the entire balance of a specific ERC20 token.
     * @param tokenContract The address of the ERC20 token contract.
     * @param recipient The address to receive the tokens.
     */
    function withdrawTokens(address tokenContract, address recipient) external onlyOwner {
        if (recipient == address(0)) revert RecipientCannotBeZeroAddress();
        IERC20 token = IERC20(tokenContract);
        uint256 balance = token.balanceOf(address(this));
        if (balance <= 0) revert NoTokenBalanceToWithdraw();
        if (!token.transfer(recipient, balance)) revert TokenTransferFailed();
    }

    /**
     * @dev Returns detailed information for all Platform NFTs currently deposited in Core
     *      including native/token assets and session statistics.
     * @return platforms An array of detailed PlatformInfo structs.
     */
    function getDepositedPlatformsWithStats() external view returns (PlatformInfo[] memory platforms) {
        require(nftContract != address(0), "WizverseCore: NFT contract not set");
        IWizverseNFT nft = IWizverseNFT(nftContract);
        IERC721Enumerable nftEnumerable = IERC721Enumerable(nftContract);

        uint256 priceUsdToNative = nft.priceUsdToNative();
        require(priceUsdToNative > 0, "WizverseCore: USD rate not set in NFT contract");

        uint256 coreBalance = nftEnumerable.balanceOf(address(this));
        uint256 platformCountLocal = 0;

        // count platforms first
        for (uint256 i = 0; i < coreBalance; i++) {
            uint256 tid = nftEnumerable.tokenOfOwnerByIndex(address(this), i);
            bool isPlat = false;
            try nft.isPlatform(tid) returns (bool res) { isPlat = res; } catch {}
            if (isPlat) platformCountLocal++;
        }

        platforms = new PlatformInfo[](platformCountLocal);
        uint256 pIdx = 0;
        for (uint256 i = 0; i < coreBalance; i++) {
            uint256 tid = nftEnumerable.tokenOfOwnerByIndex(address(this), i);
            bool isPlat = false;
            try nft.isPlatform(tid) returns (bool res) { isPlat = res; } catch {}
            if (isPlat) {
                platforms[pIdx++] = _buildPlatformInfo(tid, priceUsdToNative);
            }
        }

        return platforms;
    }

    /**
     * @dev Private helper that constructs a PlatformInfo struct for a single platform token.
     *      This is split out solely to keep the main view function below the stack-depth limit.
     */
    function _buildPlatformInfo(uint256 tokenId, uint256 priceUsdToNative)
        private
        view
        returns (PlatformInfo memory info)
    {
        IWizverseNFT nft = IWizverseNFT(nftContract);

        // nftType & original owner
        uint16 nftType = 0;
        try nft.getNFTTypeById(tokenId) returns (uint16 t) {
            nftType = t;
        } catch {}

        address originalOwner = IWizverseNFTManager(nftManager).getOriginalOwner(tokenId);

        // native balances
        uint256 nativeBalance = platformNativeAssets[tokenId];
        uint256 nativeBalanceUSD = 0;
        if (nativeBalance > 0 && priceUsdToNative > 0) {
            nativeBalanceUSD = (nativeBalance * 1e18) / priceUsdToNative;
        }

        // token balances (delegate to helper to keep stack shallow)
        (address[] memory tokenAddresses, uint256[] memory tokenBalances) = _getNonZeroTokenBalances(tokenId);

        // session data via Sessions contract
        (bool hasActive, uint256 activeCnt) = IWizverseSessions(sessions).checkPlatformHasActiveSessions(tokenId);
        uint256[] memory activeIds = new uint256[](0);
        if (hasActive && activeCnt > 0) {
            activeIds = IWizverseSessions(sessions).getActivePlatformSessions(tokenId, 0, activeCnt);
        }

        uint256 totalSessCnt = IWizverseSessions(sessions).getPlatformTotalSessions(tokenId);
        address[] memory uniquePlayers = _getUniquePlayersForPlatformSessions(activeIds);

        // totals
        uint256 totalDepositedAssets = platformTotalDeposited[tokenId];

        info = PlatformInfo({
            tokenId: tokenId,
            nftType: nftType,
            originalOwner: originalOwner,
            nativeBalance: nativeBalance,
            nativeBalanceUSD: nativeBalanceUSD,
            tokenAddresses: tokenAddresses,
            tokenBalances: tokenBalances,
            totalDeposited: totalDepositedAssets,
            totalSessions: totalSessCnt,
            activeSessionsCount: activeCnt,
            activePlayerWallets: uniquePlayers,
            activeSessions: activeIds
        });
    }

    /**
     * @dev Helper to gather non-zero token balances for a platform token.
     */
    function _getNonZeroTokenBalances(uint256 tokenId)
        private
        view
        returns (address[] memory addrs, uint256[] memory bals)
    {
        address[] memory supportedTokens = IWizverseNFT(nftContract).getSupportedTokens();
        uint256 count = 0;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (platformTokenAssets[tokenId][supportedTokens[i]] > 0) {
                count++;
            }
        }
        addrs = new address[](count);
        bals = new uint256[](count);
        uint256 k = 0;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            uint256 bal = platformTokenAssets[tokenId][supportedTokens[i]];
            if (bal > 0) {
                addrs[k] = supportedTokens[i];
                bals[k] = bal;
                k++;
            }
        }
    }

    /**
     * @dev Returns an array of token IDs for all Platform NFTs currently deposited in Core.
     * @return tokenIds An array of platform token IDs.
     */
    function getDepositedPlatforms() 
        external 
        view 
        returns (uint256[] memory tokenIds)
    {
        require(nftContract != address(0), "WizverseCore: NFT contract not set");
        IWizverseNFT nft = IWizverseNFT(nftContract);
        IERC721Enumerable nftEnumerable = IERC721Enumerable(nftContract);

        uint256 coreBalance = nftEnumerable.balanceOf(address(this));
        uint256 localPlatformCount = 0;

        // First pass: count the platforms owned by Core
        for (uint256 i = 0; i < coreBalance; i++) {
            uint256 tokenId = nftEnumerable.tokenOfOwnerByIndex(address(this), i);
            bool isPlatform = false;
            try nft.isPlatform(tokenId) returns (bool res) {
                isPlatform = res;
            } catch { }
            if (isPlatform) {
                localPlatformCount++;
            }
        }

        // Allocate the results array
        tokenIds = new uint256[](localPlatformCount);
        uint256 platformIndex = 0;

        // Second pass: populate the results array
        for (uint256 i = 0; i < coreBalance; i++) {
            uint256 tokenId = nftEnumerable.tokenOfOwnerByIndex(address(this), i);
            bool isPlatform = false;
            try nft.isPlatform(tokenId) returns (bool res) {
                isPlatform = res;
            } catch { }

            if (isPlatform) {
                tokenIds[platformIndex++] = tokenId;
            }
        }

        return tokenIds;
    }
    
    // --- Functions Delegated to WizverseSessions for Platform Session Info ---

    /**
     * @dev Check if a platform has any active sessions by calling WizverseSessions
     * @param platformTokenId The platform token ID to check
     * @return hasActiveSessions True if the platform has active sessions
     * @return activeSessionCount The number of active sessions for this platform
     */
    function checkPlatformHasActiveSessions(uint256 platformTokenId) external view returns (bool hasActiveSessions, uint256 activeSessionCount) {
        _requireSessionsSet();
        // slither-disable-next-line unused-return
        return IWizverseSessions(sessions).checkPlatformHasActiveSessions(platformTokenId);
    }
    
    /**
     * @dev Get active sessions for a specific platform by calling WizverseSessions
     * @param platformTokenId The platform token ID
     * @param offset The starting index for pagination
     * @param limit The maximum number of sessions to return
     * @return sessionIds An array of active session IDs for the platform
     */
    function getActivePlatformSessions(uint256 platformTokenId, uint256 offset, uint256 limit) external view returns (uint256[] memory sessionIds) {
        _requireSessionsSet();
        return IWizverseSessions(sessions).getActivePlatformSessions(platformTokenId, offset, limit);
    }

    /**
     * @dev Get aggregated statistics for a specific platform.
     * @param platformTokenId The platform token ID to query.
     * @return stats A PlatformStats struct containing aggregated data.
     */
    function getPlatformStats(uint256 platformTokenId) external view returns (PlatformStats memory stats) {
        _requireSessionsSet();

        // 1. Get data from WizverseSessions contract
        (bool hasActiveSessions, uint256 activeSessionsCount) = IWizverseSessions(sessions).checkPlatformHasActiveSessions(platformTokenId);
        
        uint256[] memory activeSessionIds;
        if (hasActiveSessions && activeSessionsCount > 0) {
            // Fetch all active session IDs for the platform (adjust limit if needed, here fetching all)
            activeSessionIds = IWizverseSessions(sessions).getActivePlatformSessions(platformTokenId, 0, activeSessionsCount);
        } else {
            activeSessionIds = new uint256[](0);
        }

        // Fetch total session count for the platform
        // Note: Requires getPlatformTotalSessions to be implemented in WizverseSessions
        uint256 totalSessionsCount = IWizverseSessions(sessions).getPlatformTotalSessions(platformTokenId);

        // Fetch unique player wallets from active sessions
        address[] memory uniquePlayers = _getUniquePlayersForPlatformSessions(activeSessionIds);

        // 2. Get data stored in WizverseCore
        uint256 totalDepositedAssets = platformTotalDeposited[platformTokenId];
        uint256 currentAssets = platformNativeAssets[platformTokenId];

        // 3. Assemble the struct
        stats = PlatformStats({
            platformTokenId: platformTokenId,
            totalDeposited: totalDepositedAssets,
            totalSessions: totalSessionsCount,
            activeSessionsCount: activeSessionsCount,
            activePlayerWallets: uniquePlayers,
            activeSessions: activeSessionIds, 
            currentNativeAssets: currentAssets
        });

        return stats;
    }

    /**
     * @dev Internal helper to check if an address array contains a specific address.
     * @param arr The array to check.
     * @param addr The address to look for.
     * @return True if the address is found, false otherwise.
     */
    function _contains(address[] memory arr, address addr) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == addr) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Internal helper to get unique player wallets from a list of session IDs.
     * @param sessionIds Array of session IDs to fetch players from.
     * @return uniquePlayersArray Array of unique player addresses.
     */
    function _getUniquePlayersForPlatformSessions(uint256[] memory sessionIds) internal view returns (address[] memory uniquePlayersArray) {
        if (sessionIds.length == 0) {
            return new address[](0);
        }

        // Temporary array to store potentially unique players. Size estimation can be tricky.
        // Let's estimate max 10 players per session as a starting point. Adjust if needed.
        address[] memory tempPlayers = new address[](sessionIds.length * 10); 
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < sessionIds.length; i++) {
            address[] memory sessionPlayers = IWizverseSessions(sessions).getSessionPlayers(sessionIds[i]);
            for (uint256 j = 0; j < sessionPlayers.length; j++) {
                address player = sessionPlayers[j];
                
                // Check if player is already in our temp array up to uniqueCount
                bool found = false;
                for(uint k = 0; k < uniqueCount; k++){
                    if(tempPlayers[k] == player){
                        found = true;
                        break;
                    }
                }

                if (!found) {
                     if (uniqueCount < tempPlayers.length) { // Safety check against overflow
                        tempPlayers[uniqueCount] = player;
                        uniqueCount++;
                    }
                    // Handle potential overflow if estimation is wrong (e.g., revert or log)
                }
            }
        }

        // Create final array with the exact unique count
        uniquePlayersArray = new address[](uniqueCount);
        for(uint256 i = 0; i < uniqueCount; i++){
            uniquePlayersArray[i] = tempPlayers[i];
        }

        return uniquePlayersArray; // Changed return variable name
    }

    /**
     * @dev Distribute rewards to winners from a platform's assets by sending to the Sessions contract
     * @param platformTokenId The platform token ID to use for rewards
     * @param winners Array of winner wallet addresses
     * @param amounts Array of amounts to distribute to each winner
     * @param token Token address (address(0) for native currency)
     * @return success True if the distribution was successful
     */
    function distributeWinnerRewardsToEscrow(
        uint256 platformTokenId,
        address[] calldata winners,
        uint256[] calldata amounts,
        address token
    ) external returns (bool success) {
        if (msg.sender != sessions) revert CallerNotAuthorized();
        if (winners.length != amounts.length) revert WinnersAndAmountsLengthMismatch();
        if (winners.length == 0) revert NoWinnersProvided();
        
        if (token == address(0)) {
            // Distribute native currency rewards
            uint256 totalAmount = 0;
            for (uint256 i = 0; i < amounts.length; i++) {
                totalAmount += amounts[i];
            }
            
            // Check if platform has enough assets
            if (platformNativeAssets[platformTokenId] < totalAmount) revert InsufficientPlatformAssets();
            
            // Deduct from platform's balance
            platformNativeAssets[platformTokenId] -= totalAmount;
            
            if (totalAmount <= 0) revert ETHTransferZeroNotAllowed();

            // Send total amount to Sessions contract using .call with explicit gas
            (bool sent, ) = payable(sessions).call{value: totalAmount}(""); 
            if (!sent) revert ETHTransferToSessionsFailed();
            
            emit PlatformAssetsUpdated(platformTokenId, totalAmount, token);
        } else {
            // Distribute ERC20 token rewards
            if (nftContract == address(0)) revert NFTContractNotSet();
            if (!IWizverseNFT(nftContract).isSupportedToken(token)) revert UnsupportedToken();
            
            uint256 totalAmount = 0;
            for (uint256 i = 0; i < amounts.length; i++) {
                totalAmount += amounts[i];
            }
            
            // Check if platform has enough token assets
            if (platformTokenAssets[platformTokenId][token] < totalAmount) revert InsufficientPlatformAssets();
            
            // Deduct from platform's token balance
            platformTokenAssets[platformTokenId][token] -= totalAmount;
            
            // Send total amount to Sessions contract instead of individually to winners
            IERC20 tokenContract = IERC20(token);
            if (!tokenContract.transfer(sessions, totalAmount)) revert TokenTransferFailed();
            
            emit PlatformAssetsUpdated(platformTokenId, totalAmount, token);
        }
        
        return true;
    }

    /**
     * @dev Allows a user to request claiming their rewards from sessions
     * where they are winners
     * @return success True if the request was successful
     */
    function requestToClaimRewards() external returns (bool) {
        _requireSessionsSet();
        // Call the requestToClaimRewards function in the Sessions contract
        return IWizverseSessions(sessions).requestToClaimRewards(msg.sender);
    }

    /**
     * @dev Get the original owner of a deposited NFT by calling the NFT Manager.
     * @param tokenId The token ID to query.
     * @return The address of the original owner.
     */
    function getOriginalOwner(uint256 tokenId) external view returns (address) {
        require(nftManager != address(0), "WizverseCore: NFT Manager not set");
        return IWizverseNFTManager(nftManager).getOriginalOwner(tokenId);
    }

    /**
     * @dev Convenience view that combines `getWalletWaitingRewards` and `canUserRequestRewards` in a
     *      single call so front-ends can fetch all reward-related information with one RPC request.
     * @param wallet The wallet to query rewards for.
     * @return hasWaiting      True if there are already rewards queued in the Sessions escrow
     * @return waitingRewards  Array of RewardAmount structs detailing rewards currently waiting for the wallet
     * @return platformIds     Platform IDs associated with the waiting rewards
     * @return canRequest      True if the wallet has unclaimed rewards that can be requested (from canRequestRewards)
     * @return pendingRewards  Detailed array of pending rewards broken down by token type
     */
    function getWalletRewardsCombined(address wallet)
        external
        view
        returns (
            bool hasWaiting,
            RewardAmount[] memory waitingRewards,
            uint256[] memory platformIds,
            bool canRequest,
            RewardAmount[] memory pendingRewards
        )
    {
        _requireSessionsSet();

        // Fetch waiting-wallet info (already queued in Sessions contract)
        (hasWaiting, waitingRewards, platformIds) = IWizverseSessions(sessions).getWaitingWallet(wallet);

        // Fetch request-eligibility & detailed breakdown
        (canRequest, pendingRewards) = IWizverseSessions(sessions).canRequestRewards(wallet);
    }

    // --- Health Restoration Functions ---

    /**
     * @dev Restore a wizard's health and reset respawn count by paying in native currency.
     * Health is restored to its base value as determined by the NFT contract.
     * Delegates the core logic to WizverseNFTManager.
     * @param tokenId The token ID of the wizard.
     */
    function restoreHealth(uint256 tokenId) public payable {
        if (nativePaymentsDisabled) revert NativePaymentIsDisabled();
        if (nftManager == address(0)) revert NFTManagerNotSet();
        if (nftContract == address(0)) revert NFTContractNotSet();
        if (restorationFeeUsd <= 0) revert RestorationFeeNotSetOrZero();

        // Call manager to execute logic, validate payment, and get necessary info for event & transfer
        (uint8 wizardType, uint256 feeToTransfer) = IWizverseNFTManager(nftManager).executeNativeHealthRestore(
            tokenId,
            msg.value, // Payer's sent value
            restorationFeeUsd // Fee setting from Core
        );

        // If manager call was successful and fee was validated, transfer the validated fee to the NFT contract's treasury
        address nftTreasury = IWizverseNFT(nftContract).treasury();
        if (nftTreasury == address(0)) revert NFTTreasuryNotSet();
        
        // Use Address.sendValue to forward all available gas so that
        // the transfer does not fail if `nftTreasury` is a contract
        // with a fallback function that needs >2300 gas (e.g. Gnosis Safe).
        Address.sendValue(payable(nftTreasury), feeToTransfer);

        emit HealthRestored(tokenId, wizardType, feeToTransfer, address(0), msg.sender);
    }

    /**
     * @dev Restore a wizard's health and reset respawn count by paying in a supported ERC20 token.
     * Health is restored to its base value as determined by the NFT contract.
     * Delegates the core logic and token transfer to WizverseNFTManager.
     * User must approve the WizverseNFTManager contract to spend their tokens beforehand.
     * @param tokenId The token ID of the wizard.
     * @param token The address of the ERC20 token to pay with.
     */
    function restoreHealthToken(uint256 tokenId, address token) public {
        if (nftManager == address(0)) revert NFTManagerNotSet();
        if (restorationFeeUsd <= 0) revert RestorationFeeNotSetOrZero();

        // Call manager to execute logic, transfer tokens, and get necessary info for event
        (uint8 wizardType, uint256 actualFeePaid) = IWizverseNFTManager(nftManager).executeTokenHealthRestore(
            tokenId,
            token,
            restorationFeeUsd, // Fee setting from Core
            msg.sender // The original payer who must have approved NFT Manager
        );

        emit HealthRestored(tokenId, wizardType, actualFeePaid, token, msg.sender);
    }
}


