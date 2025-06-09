// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IWizverseNFT.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "hardhat/console.sol";

interface IWizverseCore {
    function minFeeUsd() external view returns (uint256);
    function treasury() external view returns (address);
    function updatePlatformAssets(uint256 platformTokenId, uint256 amount, address token) external;
    function checkPlatformHasActiveSessions(uint256 platformTokenId) external view returns (bool hasActiveSessions, uint256 activeSessionCount);
    function getActivePlatformSessions(uint256 platformTokenId, uint256 offset, uint256 limit) external view returns (uint256[] memory sessionIds);
    function getDepositedPlatforms() external view returns (uint256[] memory);
}

contract WizverseNFTManager is Ownable, ReentrancyGuard {
    using Address for address payable;
    using Strings for uint256;

    // Address of the NFT contract.
    address public nftContract;
    // Reference to the Core contract.
    address public core;

    // Mapping from token ID to the original owner.
    mapping(uint256 => address) public nftOriginalOwners;
    
    // Core token index counter.
    uint256 public coreTokenCount;
    mapping(uint256 => uint256) internal _coreTokenByIndex;
    
    // --- Categorization mappings ---
    mapping(uint8 => uint256[]) internal _wizardTypeToTokenIds;
    mapping(uint16 => uint256[]) internal _platformTypeToTokenIds;
    mapping(uint8 => uint256[]) internal _weaponTypeToTokenIds;
    
    // Whitelist of approved tokens
    mapping(address => bool) public approvedTokens;
    
    constructor() Ownable(msg.sender) {}
    
    /// @dev Modifier to ensure NFT contract is set.
    modifier nftContractSet() {
        require(nftContract != address(0), "WizverseNFTManager: NFT contract not set");
        _;
    }
    
    /// @dev Modifier to ensure Core contract is set.
    modifier coreSet() {
        require(core != address(0), "WizverseNFTManager: Core contract not set");
        _;
    }

    /// @dev Modifier to ensure token is approved
    modifier tokenApproved(address token) {
        require(approvedTokens[token], "WizverseNFTManager: token not approved");
        _;
    }

    /**
     * @dev Sets the address of the NFT contract.
     */
    function setNFTContract(address _nftContract) external onlyOwner {
        require(_nftContract != address(0), "WizverseNFTManager: zero address");
        nftContract = _nftContract;
    }
    
    /**
     * @dev Sets the Core contract address.
     */
    function setCore(address _core) external onlyOwner {
        require(_core != address(0), "WizverseNFTManager: zero core address");
        core = _core;
    }

    /**
     * @dev Approves a token for use in the contract
     */
    function approveToken(address token) external onlyOwner {
        require(token != address(0), "WizverseNFTManager: invalid token");
        approvedTokens[token] = true;
    }

    /**
     * @dev Revokes approval for a token
     */
    function revokeToken(address token) external onlyOwner {
        approvedTokens[token] = false;
    }

    /**
     * @dev Internal function to safely transfer ERC20 tokens
     */
    // slither-disable-next-line arbitrary-send-erc20
    function _safeTransferERC20(IERC20 token, address from, address to, uint256 amount) internal {
        // Verify the sender is authorized to transfer tokens
        require(msg.sender == from || msg.sender == core || msg.sender == nftContract, "WizverseNFTManager: unauthorized transfer");
        
        // Skip validation for transfers to self - these are just bookkeeping operations
        if (from == to) {
            bool selfTransferSuccess = token.transferFrom(from, to, amount);
            require(selfTransferSuccess, "WizverseNFTManager: token transfer failed");
            return;
        }
        
        // Get the current allowance and balance
        uint256 currentAllowance = token.allowance(from, address(this));
        uint256 currentBalance = token.balanceOf(from);
        
        // Verify sufficient allowance and balance
        require(currentAllowance >= amount, "WizverseNFTManager: insufficient allowance");
        require(currentBalance >= amount, "WizverseNFTManager: insufficient balance");
        
        // Store initial balances for verification
        uint256 initialFromBalance = token.balanceOf(from);
        uint256 initialToBalance = token.balanceOf(to);
        
        // Perform the transfer
        bool success = token.transferFrom(from, to, amount);
        require(success, "WizverseNFTManager: token transfer failed");
        
        // Get final balances
        uint256 finalFromBalance = token.balanceOf(from);
        uint256 finalToBalance = token.balanceOf(to);
        
        // The sender's balance should have decreased
        require(finalFromBalance < initialFromBalance, "WizverseNFTManager: sender balance didn't decrease");
        
        // The recipient's balance should have increased
        require(finalToBalance > initialToBalance, "WizverseNFTManager: recipient balance didn't increase");
    }

    /**
     * @dev Internal function to safely transfer ERC721 tokens
     */
    // slither-disable-next-line arbitrary-send-erc20
    function _safeTransferERC721(IERC721 token, address from, address to, uint256 tokenId) internal {
        // Verify the sender is authorized to transfer tokens
        require(msg.sender == from || msg.sender == core, "WizverseNFTManager: unauthorized transfer");
        
        // Verify the token exists and is owned by from
        require(token.ownerOf(tokenId) == from, "WizverseNFTManager: token not owned by from");
        
        // Verify the token is approved for transfer
        require(token.getApproved(tokenId) == address(this) || 
                token.isApprovedForAll(from, address(this)), 
                "WizverseNFTManager: token not approved");
        
        // Store initial owner for verification
        address initialOwner = token.ownerOf(tokenId);
        
        // Perform the transfer
        token.transferFrom(from, to, tokenId);
        
        // Verify the transfer was successful
        require(token.ownerOf(tokenId) == to, "WizverseNFTManager: transfer verification failed");
        require(initialOwner != to, "WizverseNFTManager: owner unchanged");
    }

    /**
     * @dev Deposit an NFT with native currency.
     */
    function addNFT(uint256 tokenId, address sender) external payable nonReentrant coreSet nftContractSet returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        _checkNFTConditions(tokenId, sender);
        uint256 required = IWizverseCore(core).minFeeUsd();
        require(msg.value >= required, "WizverseNFTManager: insufficient native payment");
        
        // Record deposit before external calls
        _recordNFTDeposit(tokenId, sender);
        
        // Perform the NFT transfer
        _safeTransferERC721(IERC721(nftContract), sender, core, tokenId);
        
        // Send funds to treasury
        (bool sent, ) = IWizverseCore(core).treasury().call{value: msg.value}("");
        require(sent, "WizverseNFTManager: failed to send funds");
        
        return true;
    }
    
    /**
     * @dev Deposit a batch of NFTs with native currency.
     */
    function addNFTBatch(uint256[] calldata tokenIds, address sender) external payable nonReentrant coreSet nftContractSet returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        require(tokenIds.length > 0, "WizverseNFTManager: no token IDs provided");
        
        // Fetch fee in USD from Core and rate from NFT contract
        uint256 minFeeUsd = IWizverseCore(core).minFeeUsd();
        uint256 rate = IWizverseNFT(nftContract).priceUsdToNative();
        require(rate > 0, "WizverseNFTManager: Native exchange rate not set in NFT contract");

        // Calculate required total native fee directly
        uint256 requiredTotalNative = (minFeeUsd * rate * tokenIds.length) / 1e18;
        
        // Check against calculated native fee
        require(msg.value >= requiredTotalNative, "WizverseNFTManager: insufficient native payment for batch");
        
        // Record deposits before external calls
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 currentTokenId = tokenIds[i];
            _checkNFTConditions(currentTokenId, sender);
            _recordNFTDeposit(currentTokenId, sender);
        }
        
        // Perform NFT transfers
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _safeTransferERC721(IERC721(nftContract), sender, core, tokenIds[i]);
        }
        
        // Send *entire msg.value* to treasury (as fee is just a minimum check)
        (bool sent, ) = IWizverseCore(core).treasury().call{value: msg.value}("");
        require(sent, "WizverseNFTManager: failed to send funds");
        
        return true;
    }
    
    /**
     * @dev Deposit a batch of NFTs with native currency, allocating a percentage to a platform.
     */
    function addNFTBatchTo(
        uint256 platformTokenId,
        uint256[] calldata tokenIds, 
        address sender,
        uint256 percentForPlatform
    ) external payable nonReentrant coreSet nftContractSet returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        require(tokenIds.length > 0, "WizverseNFTManager: no token IDs provided");
        require(percentForPlatform <= 10000, "WizverseNFTManager: invalid percentage");
        
        // Verify platform token exists, if provided
        if (platformTokenId != 0) {
            IERC721 nft = IERC721(nftContract);
            require(nft.ownerOf(platformTokenId) == core, "WizverseNFTManager: platform not in core");
        }
        
        // Fetch fee in USD from Core and rate from NFT contract
        uint256 minFeeUsd = IWizverseCore(core).minFeeUsd();
        uint256 rate = IWizverseNFT(nftContract).priceUsdToNative();
        require(rate > 0, "WizverseNFTManager: Native exchange rate not set in NFT contract");

        // Calculate required total native fee directly
        uint256 requiredTotalNative = (minFeeUsd * rate * tokenIds.length) / 1e18;
        
        // Check against calculated native fee
        require(msg.value >= requiredTotalNative, "WizverseNFTManager: insufficient native payment for batch");
        
        // Record deposits before external calls
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 currentTokenId = tokenIds[i];
            _checkNFTConditions(currentTokenId, sender);
            _recordNFTDeposit(currentTokenId, sender);
        }
        
        // Calculate split based on the *entire msg.value*
        uint256 platformAmount = (msg.value * percentForPlatform) / 10000;
        uint256 treasuryAmount = msg.value - platformAmount;
        
        // Send to treasury
        if (treasuryAmount > 0) {
            (bool sent, ) = IWizverseCore(core).treasury().call{value: treasuryAmount}("");
            require(sent, "WizverseNFTManager: failed to send funds to treasury");
        }
        
        // Send platform fee to Core contract and update platform assets, if a platform is specified
        if (platformTokenId != 0 && platformAmount > 0) {
            (bool sent, ) = core.call{value: platformAmount}("");
            require(sent, "WizverseNFTManager: failed to send funds to core");
            
            // Update platform assets in Core
            IWizverseCore(core).updatePlatformAssets(platformTokenId, platformAmount, address(0));
        } else if (platformTokenId == 0 && platformAmount > 0) {
            // If no platform, the platform's share goes to the treasury as well
            (bool sent, ) = IWizverseCore(core).treasury().call{value: platformAmount}("");
            require(sent, "WizverseNFTManager: failed to send funds to treasury");
        }
        
        // Perform NFT transfers
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _safeTransferERC721(IERC721(nftContract), sender, core, tokenIds[i]);
        }
        
        return true;
    }
    
    /**
     * @dev Deposit an NFT using an ERC20 token.
     */
    function addNFTToken(uint256 tokenId, address paymentToken, uint256 tokenAmount, address sender) external nonReentrant coreSet nftContractSet tokenApproved(paymentToken) returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        uint256 rate = IWizverseNFT(nftContract).tokenExchangeRates(paymentToken);
        require(rate > 0, "WizverseNFTManager: exchange rate not set for token");
        uint256 requiredTokens = (IWizverseCore(core).minFeeUsd() * rate) / 1e18;
        require(tokenAmount >= requiredTokens, "WizverseNFTManager: insufficient token payment");
        
        _checkNFTConditions(tokenId, sender);
        
        // Record deposit before external calls
        _recordNFTDeposit(tokenId, sender);
        
        // Perform token transfer
        _safeTransferERC20(IERC20(paymentToken), sender, IWizverseCore(core).treasury(), tokenAmount);
        
        // Perform NFT transfer
        _safeTransferERC721(IERC721(nftContract), sender, core, tokenId);
        
        return true;
    }
    
    /**
     * @dev Deposit a batch of NFTs using an ERC20 token.
     */
    function addNFTBatchToken(uint256[] calldata tokenIds, address paymentToken, uint256 tokenAmount, address sender) external nonReentrant coreSet nftContractSet tokenApproved(paymentToken) returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        require(tokenIds.length > 0, "WizverseNFTManager: no token IDs provided");
        uint256 rate = IWizverseNFT(nftContract).tokenExchangeRates(paymentToken);
        require(rate > 0, "WizverseNFTManager: exchange rate not set for token");
        uint256 requiredTotal = (IWizverseCore(core).minFeeUsd() * tokenIds.length * rate) / 1e18;
        require(tokenAmount >= requiredTotal, "WizverseNFTManager: insufficient token payment for batch");
        
        // Record deposits before external calls
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 currentTokenId = tokenIds[i];
            _checkNFTConditions(currentTokenId, sender);
            _recordNFTDeposit(currentTokenId, sender);
        }
        
        // Perform token transfer
        _safeTransferERC20(IERC20(paymentToken), sender, IWizverseCore(core).treasury(), tokenAmount);
        
        // Perform NFT transfers
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _safeTransferERC721(IERC721(nftContract), sender, core, tokenIds[i]);
        }
        
        return true;
    }
    
    /**
     * @dev Deposit a batch of NFTs using an ERC20 token, allocating a percentage to a platform.
     */
    function addNFTBatchTokenTo(
        uint256 platformTokenId,
        uint256[] calldata tokenIds,
        address token,
        uint256 tokenAmount,
        address sender,
        uint256 percentForPlatform
    ) external nonReentrant coreSet nftContractSet tokenApproved(token) returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        require(tokenIds.length > 0, "WizverseNFTManager: no token IDs provided");
        require(percentForPlatform <= 10000, "WizverseNFTManager: invalid percentage");
        
        // Verify platform token exists, if provided
        if (platformTokenId != 0) {
            IERC721 nft = IERC721(nftContract);
            require(nft.ownerOf(platformTokenId) == core, "WizverseNFTManager: platform not in core");
        }
        
        uint256 rate = IWizverseNFT(nftContract).tokenExchangeRates(token);
        require(rate > 0, "WizverseNFTManager: exchange rate not set for token");
        uint256 requiredTotal = (IWizverseCore(core).minFeeUsd() * tokenIds.length * rate) / 1e18;
        require(tokenAmount >= requiredTotal, "WizverseNFTManager: insufficient token payment for batch");
        
        // Record deposits before external calls
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 currentTokenId = tokenIds[i];
            _checkNFTConditions(currentTokenId, sender);
            _recordNFTDeposit(currentTokenId, sender);
        }
        
        // Calculate split
        uint256 platformAmount = (tokenAmount * percentForPlatform) / 10000;
        uint256 treasuryAmount = tokenAmount - platformAmount;
        
        // Transfer tokens to treasury
        if (treasuryAmount > 0) {
            _safeTransferERC20(IERC20(token), sender, IWizverseCore(core).treasury(), treasuryAmount);
        }
        
        // Transfer platform fee to Core contract, if a platform is specified
        if (platformTokenId != 0 && platformAmount > 0) {
            _safeTransferERC20(IERC20(token), sender, core, platformAmount);
            IWizverseCore(core).updatePlatformAssets(platformTokenId, platformAmount, token);
        } else if (platformTokenId == 0 && platformAmount > 0) {
            // If no platform, the platform's share goes to the treasury as well
            _safeTransferERC20(IERC20(token), sender, IWizverseCore(core).treasury(), platformAmount);
        }
        
        // Perform NFT transfers
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _safeTransferERC721(IERC721(nftContract), sender, core, tokenIds[i]);
        }
        
        return true;
    }
    
    /**
     * @dev Return a deposited NFT.
     */
    function returnNFT(uint256 tokenId, address sender) external nonReentrant nftContractSet returns (bool) {
        require(msg.sender == sender || msg.sender == core, "WizverseNFTManager: unauthorized caller");
        address originalOwner = nftOriginalOwners[tokenId];
        require(originalOwner != address(0), "WizverseNFTManager: NFT not deposited");
        require(originalOwner == sender, "WizverseNFTManager: caller is not the original owner");
        
        // Check if this is a platform token
        IWizverseNFT nft = IWizverseNFT(nftContract);
        bool isPlatform = false;
        try nft.isPlatform(tokenId) returns (bool res) {
            isPlatform = res;
        } catch {
            isPlatform = false;
        }
        
        // If this is a platform, check for active sessions
        if (isPlatform) {
            (bool hasActiveSessions, uint256 sessionCount) = IWizverseCore(core).checkPlatformHasActiveSessions(tokenId);
            require(!hasActiveSessions, string(abi.encodePacked(
                "WizverseNFTManager: Platform has ", 
                sessionCount.toString(), 
                " active sessions. Cannot return until sessions are completed."
            )));
        }
        
        // Update state BEFORE external call (Checks-Effects-Interactions pattern)
        nftOriginalOwners[tokenId] = address(0);

        return true;
    }
    
    /* ================= Internal Functions ================= */
    
    /**
     * @dev Checks that the NFT can be deposited.
     */
    function _checkNFTConditions(uint256 tokenId, address sender) internal view nftContractSet {
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == sender, "WizverseNFTManager: sender not owner");
    }
    
    /**
     * @dev Records deposit information after the NFT has been transferred.
     */
    function _recordNFTDeposit(uint256 tokenId, address sender) internal nftContractSet {
        nftOriginalOwners[tokenId] = sender;
        _coreTokenByIndex[coreTokenCount] = tokenId;
        coreTokenCount++;
        
        // Attempt internal categorization.
        try this._safelyCategorizeNFT(tokenId) {
            // Categorization succeeded.
        } catch {
            // Ignore categorization failure.
        }
    }
    
    /**
     * @dev Internal function to classify an NFT according to its attributes.
     */
    // slither-disable-next-line unused-return
    function _safelyCategorizeNFT(uint256 tokenId) external nftContractSet {
        require(msg.sender == address(this), "WizverseNFTManager: invalid call");
        IWizverseNFT nft = IWizverseNFT(nftContract);
        
        // Categorize as Wizard.
        bool isWizard = false;
        try nft.isWizard(tokenId) returns (bool res) {
            isWizard = res;
        } catch {
            isWizard = false;
        }
        if (isWizard) {
            try nft.getWizardAttributes(tokenId) returns (WizardAttributes memory attrs) {
                if (attrs.wizardType <= 9) { // Validate wizardType from struct
                    _wizardTypeToTokenIds[attrs.wizardType].push(tokenId);
                    emit NFTTypeCategorized(tokenId, "Wizard", attrs.wizardType);
                    return; // Early return after successful categorization
                }
            } catch { }
        }
        
        // Categorize as Weapon.
        bool isWeapon = false;
        try nft.isWeapon(tokenId) returns (bool res) {
            isWeapon = res;
        } catch {
            isWeapon = false;
        }
        if (isWeapon) {
            try nft.getWeaponAttributes(tokenId) returns (WeaponAttributes memory attrs) {
                if (attrs.weaponType >= 10 && attrs.weaponType <= 19) { // Validate weaponType from struct
                    _weaponTypeToTokenIds[attrs.weaponType].push(tokenId);
                    emit NFTTypeCategorized(tokenId, "Weapon", attrs.weaponType);
                    return; // Early return after successful categorization
                }
            } catch { }
        }
        
        // Categorize as Platform.
        bool isPlatform = false;
        try nft.isPlatform(tokenId) returns (bool res) {
            isPlatform = res;
        } catch {
            isPlatform = false;
        }
        if (isPlatform) {
            try nft.getPlatformAttributes(tokenId) returns (PlatformAttributes memory attrs) {
                if (attrs.platformType >= 100) { // Validate platformType from struct
                    _platformTypeToTokenIds[attrs.platformType].push(tokenId);
                    emit NFTTypeCategorized(tokenId, "Platform", attrs.platformType);
                    return; // Early return after successful categorization
                }
            } catch { }
        }
        
        // If we get here, no categorization was successful
        emit NFTCategorizationFailed(tokenId);
    }
    
    /**
     * @dev Returns an array of deposited NFT token IDs for a given wallet.
     */
    function getDepositedNFTs(address wallet) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < coreTokenCount; i++) {
            uint256 tokenId = _coreTokenByIndex[i];
            if (nftOriginalOwners[tokenId] == wallet) {
                count++;
            }
        }
        uint256[] memory result = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < coreTokenCount; i++) {
            uint256 tokenId = _coreTokenByIndex[i];
            if (nftOriginalOwners[tokenId] == wallet) {
                result[j] = tokenId;
                j++;
            }
        }
        return result;
    }

    /**
     * @dev Claim NFTs with native currency and mint them via the NFT contract
     */
    event BatchClaimNFT(address indexed sender, uint16[] types, address indexed referrer, uint256 totalPrice, uint256 referrerAmount, bool isPlatformDistribution);
    function batchClaimNFT(uint16[] calldata types, address sender, address referrer, bool isPlatformDistribution) external payable nonReentrant coreSet nftContractSet returns (uint256[] memory tokenIds) {
        require(msg.sender == sender || msg.sender == core || msg.sender == nftContract, "WizverseNFTManager: unauthorized caller");
        // Calculate total price
        uint256 totalPrice = 0;
        for (uint256 i = 0; i < types.length; i++) {
            uint16 nftType = types[i];
            // Delegate price calculation to NFT contract
            if (nftType <= 9) { // Wizard type
                totalPrice += IWizverseNFT(nftContract).getPriceNative(uint8(nftType), type(uint8).max, type(uint16).max);
            } else if (nftType >= 10 && nftType <= 19) { // Weapon type
                totalPrice += IWizverseNFT(nftContract).getPriceNative(type(uint8).max, uint8(nftType), type(uint16).max);
            } else if (nftType >= 100) { // Platform type
                totalPrice += IWizverseNFT(nftContract).getPriceNative(type(uint8).max, type(uint8).max, nftType);
            } else {
                revert("WizverseNFTManager: invalid NFT type");
            }
        }
        require(msg.value >= totalPrice, "WizverseNFTManager: insufficient payment");
        uint256 paymentAmount = msg.value;
        address treasuryAddress = IWizverseCore(core).treasury();
        address coreAddress = core;
        require(coreAddress != address(0), "WizverseNFTManager: Core address not set");
        require(treasuryAddress != address(0), "WizverseNFTManager: Treasury address not set");
        uint256 feePercent = IWizverseNFT(nftContract).coreFeePercent();
        require(feePercent <= 10000, "WizverseNFTManager: Invalid core fee percent from NFT");
        uint256 referrerFeePercent = IWizverseNFT(nftContract).referrerFeePercent();
        require(referrerFeePercent <= 10000, "WizverseNFTManager: Invalid referrer fee percent");
        uint256 referrerAmount = 0;
        if (referrer != address(0) && referrerFeePercent > 0) {
            referrerAmount = (paymentAmount * referrerFeePercent) / 10000;
            payable(referrer).sendValue(referrerAmount);
        }
        emit BatchClaimNFT(sender, types, referrer, totalPrice, referrerAmount, isPlatformDistribution);
        uint256 remainingAmount = paymentAmount - referrerAmount;

        if (isPlatformDistribution) {
            uint256 coreAmount = (remainingAmount * feePercent) / 10000;
            uint256 treasuryAmount = remainingAmount - coreAmount;
            uint256[] memory depositedPlatforms = IWizverseCore(core).getDepositedPlatforms();
            uint256 platformCount = depositedPlatforms.length;
            uint256 totalPlatformAmountToSend = 0;
            uint256 amountPerPlatform = 0;
            uint256 remainderToSend = 0;
            if (platformCount > 0 && coreAmount > 0) {
                amountPerPlatform = coreAmount / platformCount;
                remainderToSend = coreAmount % platformCount;
                totalPlatformAmountToSend = coreAmount - remainderToSend;
            } else {
                remainderToSend = coreAmount;
            }
            if (totalPlatformAmountToSend > 0) {
                payable(coreAddress).sendValue(totalPlatformAmountToSend);
            }
            if (remainderToSend > 0) {
                payable(coreAddress).sendValue(remainderToSend);
            }
            if (platformCount > 0 && amountPerPlatform > 0) {
                for (uint256 i = 0; i < platformCount; i++) {
                    uint256 platformId = depositedPlatforms[i];
                    IWizverseCore(core).updatePlatformAssets(platformId, amountPerPlatform, address(0));
                }
            }
            if (treasuryAmount > 0) {
                payable(treasuryAddress).sendValue(treasuryAmount);
            }
        } else {
            // Send all remaining funds to treasury
            if (remainingAmount > 0) {
                payable(treasuryAddress).sendValue(remainingAmount);
            }
        }

        tokenIds = IWizverseNFT(nftContract).batchMintNFTs(sender, types);
        return tokenIds;
    }

    /**
     * @dev Claim NFTs with ERC20 token and mint them via the NFT contract
     */
    function batchClaimNFTToken(uint16[] calldata types, address token, address sender, address referrer, bool isPlatformDistribution) external nonReentrant coreSet nftContractSet tokenApproved(token) returns (uint256[] memory tokenIds) {
        require(msg.sender == sender || msg.sender == core || msg.sender == nftContract, "WizverseNFTManager: unauthorized caller");
        uint256 rate = IWizverseNFT(nftContract).tokenExchangeRates(token);
        require(rate > 0, "WizverseNFTManager: exchange rate not set for token");
        uint256 totalPrice = 0;
        for (uint256 i = 0; i < types.length; i++) {
            uint16 nftType = types[i];
            if (nftType <= 9) {
                totalPrice += IWizverseNFT(nftContract).getPriceToken(uint8(nftType), type(uint8).max, type(uint16).max, token);
            } else if (nftType >= 10 && nftType <= 19) {
                totalPrice += IWizverseNFT(nftContract).getPriceToken(type(uint8).max, uint8(nftType), type(uint16).max, token);
            } else if (nftType >= 100) {
                totalPrice += IWizverseNFT(nftContract).getPriceToken(type(uint8).max, type(uint8).max, nftType, token);
            } else {
                revert("WizverseNFTManager: invalid NFT type");
            }
        }
        IERC20 tokenContract = IERC20(token);
        require(tokenContract.allowance(sender, address(this)) >= totalPrice, "WizverseNFTManager: Insufficient token allowance for NFT Manager");
        uint256 paymentAmount = totalPrice;
        address treasuryAddress = IWizverseCore(core).treasury();
        address coreAddress = core;
        require(coreAddress != address(0), "WizverseNFTManager: Core address not set");
        require(treasuryAddress != address(0), "WizverseNFTManager: Treasury address not set");
        uint256 feePercent = IWizverseNFT(nftContract).coreFeePercent();
        require(feePercent <= 10000, "WizverseNFTManager: Invalid core fee percent from NFT");
        uint256 referrerFeePercent = IWizverseNFT(nftContract).referrerFeePercent();
        require(referrerFeePercent <= 10000, "WizverseNFTManager: Invalid referrer fee percent");
        uint256 referrerAmount = 0;
        if (referrer != address(0) && referrerFeePercent > 0) {
            referrerAmount = (paymentAmount * referrerFeePercent) / 10000;
            _safeTransferERC20(tokenContract, sender, referrer, referrerAmount);
        }
        emit BatchClaimNFT(sender, types, referrer, totalPrice, referrerAmount, isPlatformDistribution);
        uint256 remainingAmount = paymentAmount - referrerAmount;

        if (isPlatformDistribution) {
            uint256 coreAmount = (remainingAmount * feePercent) / 10000;
            uint256 treasuryAmount = remainingAmount - coreAmount;
            uint256[] memory depositedPlatforms = IWizverseCore(core).getDepositedPlatforms();
            uint256 platformCount = depositedPlatforms.length;
            uint256 totalPlatformAmountToTransfer = 0;
            uint256 amountPerPlatform = 0;
            uint256 remainderToTransfer = 0;
            if (platformCount > 0 && coreAmount > 0) {
                amountPerPlatform = coreAmount / platformCount;
                remainderToTransfer = coreAmount % platformCount;
                totalPlatformAmountToTransfer = coreAmount - remainderToTransfer;
            } else {
                remainderToTransfer = coreAmount;
            }
            if (totalPlatformAmountToTransfer > 0) {
                _safeTransferERC20(tokenContract, sender, coreAddress, totalPlatformAmountToTransfer);
            }
            if (remainderToTransfer > 0) {
                _safeTransferERC20(tokenContract, sender, coreAddress, remainderToTransfer);
            }
            if (platformCount > 0 && amountPerPlatform > 0) {
                for (uint256 i = 0; i < platformCount; i++) {
                    uint256 platformId = depositedPlatforms[i];
                    IWizverseCore(core).updatePlatformAssets(platformId, amountPerPlatform, token);
                }
            }
            if (treasuryAmount > 0) {
                _safeTransferERC20(tokenContract, sender, treasuryAddress, treasuryAmount);
            }
        } else {
            // Send all remaining funds to treasury
            if (remainingAmount > 0) {
                _safeTransferERC20(tokenContract, sender, treasuryAddress, remainingAmount);
            }
        }

        tokenIds = IWizverseNFT(nftContract).batchMintNFTs(sender, types);
        return tokenIds;
    }

    /**
     * @dev Calculate platform type based on wizard type
     */
    function calculatePlatformType(uint8 wizardType) public pure returns (uint16 platformType) {
        require(wizardType <= 9, "WizverseNFTManager: invalid wizard type");
        
        // Deterministic mapping of wizard type to platform types
        // NOTE: This logic might need to be extended if wizard types 5-9 map to different platform types.
        // For now, types 5-9 will behave like type 4 was previously.
        if (wizardType == 0 || wizardType == 1 || wizardType == 2) {
            return 100; // Health platform
        } else if (wizardType == 3) {
            return 101; // Defense platform
        } else { // wizardType >= 4
            return 102; // Speed platform
        }
    }

    /**
     * @dev Returns the original owner recorded for a deposited NFT.
     */
    function getOriginalOwner(uint256 tokenId) external view returns (address) {
        return nftOriginalOwners[tokenId];
    }

    /**
     * @dev Event emitted when an NFT is categorized
     */
    event NFTTypeCategorized(uint256 indexed tokenId, string nftType, uint256 typeId);
    
    /**
     * @dev Event emitted when NFT categorization fails
     */
    event NFTCategorizationFailed(uint256 indexed tokenId);

    // --- Health Restoration Functions ---

    /**
     * @dev Executes health restoration for a wizard using native currency.
     * Called by WizverseCore, which holds the payment from the user.
     * This function validates the payment, transfers it to the NFT treasury, and updates wizard attributes.
     * @param tokenId The token ID of the wizard.
     * @param amountPaidByPayer The native currency amount sent by the user to WizverseCore.
     * @param restorationFeeUsdFromCore The health restoration fee in USD, as set in WizverseCore.
     * @return wizardType The type of the wizard.
     * @return actualFeePaid The actual native fee that was required and transferred.
     */
    function executeNativeHealthRestore(
        uint256 tokenId,
        uint256 amountPaidByPayer,
        uint256 restorationFeeUsdFromCore
    ) external nonReentrant nftContractSet returns (uint8 wizardType, uint256 actualFeePaid) {
        require(msg.sender == core, "WizverseNFTManager: Caller must be Core contract");
        IWizverseNFT nft = IWizverseNFT(nftContract);

        require(nft.isWizard(tokenId), "WizverseNFTManager: Token is not a valid wizard");
        require(restorationFeeUsdFromCore > 0, "WizverseNFTManager: Restoration fee not set or is zero in Core");
        
        address nftTreasury = nft.treasury();
        uint256 nftPriceUsdToNative = nft.priceUsdToNative();

        require(nftPriceUsdToNative > 0, "WizverseNFTManager: Native price rate not set in NFT contract");
        require(nftTreasury != address(0), "WizverseNFTManager: Treasury address not set in NFT contract");

        uint256 expectedFee = (restorationFeeUsdFromCore * nftPriceUsdToNative) / 1e18;

        // Accept any payment that is equal or greater than the expected fee (prevents rounding-error reverts)
        require(amountPaidByPayer >= expectedFee, "WizverseNFTManager: Insufficient native payment amount");

        // Treat the amount actually paid by the user as the fee to forward to the treasury so the
        // emitted event always reflects the real value that left the user's wallet.
        actualFeePaid = amountPaidByPayer;

        // Note: WizverseCore will handle the transfer of `amountPaidByPayer` to nftTreasury.
        // This function just validates and performs the attribute update.

        WizardAttributes memory currentAttrs = nft.getWizardAttributes(tokenId);
        uint16 fullHealth = nft.getRestoredHealth(tokenId);
        wizardType = currentAttrs.wizardType;

        nft.updateWizardAttributes(
            tokenId, 
            fullHealth, 
            currentAttrs.atk, 
            currentAttrs.def, 
            currentAttrs.spd, 
            currentAttrs.exp, 
            currentAttrs.score, 
            currentAttrs.hpRe, 
            currentAttrs.hpLe, 
            0 // respawnCount reset to 0
        );
        
        return (wizardType, actualFeePaid);
    }

    /**
     * @dev Executes health restoration for a wizard using an ERC20 token.
     * Called by WizverseCore. The user (payer) must have approved this Manager contract to spend their tokens.
     * This function validates the fee, transfers tokens from payer to NFT treasury, and updates wizard attributes.
     * @param tokenId The token ID of the wizard.
     * @param tokenAddress The address of the ERC20 token used for payment.
     * @param restorationFeeUsdFromCore The health restoration fee in USD, as set in WizverseCore.
     * @param payer The original user who initiated the restoration and will pay with tokens.
     * @return wizardType The type of the wizard.
     * @return actualFeePaid The actual token fee that was required and transferred.
     */
    function executeTokenHealthRestore(
        uint256 tokenId,
        address tokenAddress,
        uint256 restorationFeeUsdFromCore,
        address payer
    ) external nonReentrant nftContractSet returns (uint8 wizardType, uint256 actualFeePaid) {
        require(msg.sender == core, "WizverseNFTManager: Caller must be Core contract");
        IWizverseNFT nft = IWizverseNFT(nftContract);

        require(nft.isWizard(tokenId), "WizverseNFTManager: Token is not a valid wizard");
        require(restorationFeeUsdFromCore > 0, "WizverseNFTManager: Restoration fee not set or is zero in Core");
        
        address nftTreasury = nft.treasury();
        uint256 tokenRate = nft.tokenExchangeRates(tokenAddress);

        require(tokenRate > 0, "WizverseNFTManager: Token not supported or rate not set in NFT contract");
        require(nftTreasury != address(0), "WizverseNFTManager: Treasury address not set in NFT contract");

        actualFeePaid = (restorationFeeUsdFromCore * tokenRate) / 1e18;
        require(actualFeePaid > 0, "WizverseNFTManager: Calculated token fee is zero");

        // Ensure the payer has approved enough tokens for this manager to spend
        IERC20 tokenContract = IERC20(tokenAddress);
        require(
            tokenContract.allowance(payer, address(this)) >= actualFeePaid,
            "WizverseNFTManager: Insufficient token allowance for health restore"
        );

        // Optional safeguard: if the wizard was deposited via the manager, ensure the payer matches
        if (nftOriginalOwners[tokenId] != address(0)) {
            require(payer == nftOriginalOwners[tokenId], "WizverseNFTManager: payer is not original owner of wizard");
        }

        // Safely transfer tokens from payer to the NFT treasury using internal helper
        _safeTransferERC20(tokenContract, payer, nftTreasury, actualFeePaid);

        WizardAttributes memory currentAttrs = nft.getWizardAttributes(tokenId);
        uint16 fullHealth = nft.getRestoredHealth(tokenId);
        wizardType = currentAttrs.wizardType;

        nft.updateWizardAttributes(
            tokenId, 
            fullHealth, 
            currentAttrs.atk, 
            currentAttrs.def, 
            currentAttrs.spd, 
            currentAttrs.exp, 
            currentAttrs.score, 
            currentAttrs.hpRe, 
            currentAttrs.hpLe, 
            0 // respawnCount reset to 0
        );
        
        return (wizardType, actualFeePaid);
    }
}