// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IWizverseNFTManager.sol";  // <-- add this import
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

// Minimal interface to query the NFT Manager address from the Core contract
interface IWizverseCoreMinimal {
    function nftManager() external view returns (address);
}

// Custom Errors
error ZeroAddress();
error InvalidWizardType();
error InvalidWeaponType();
error InvalidPlatformType();
error PriceCalculationUnderflow();
error InvalidPrice();
error TokenNotSupported();
error NotOwner(address expectedOwner, address actualOwner, uint256 tokenId);
error NotOwnerOfWizard(uint256 tokenId);
error NotOwnerOfWeapon(uint256 tokenId);
error NotOwnerOfPlatform(uint256 tokenId);
error InvalidWizardId(uint256 tokenId);
error InvalidWeaponId(uint256 tokenId);
error InvalidPlatformId(uint256 tokenId);
error NoWeaponEquipped(uint256 wizardId);
error NoPlatformEquipped(uint256 wizardId);
error NFTDoesNotExist(uint256 tokenId);
error CallerNotOwnerOrCore();
error URIQueryForNonexistentToken(uint256 tokenId);
error PriceMustBePositive();
error InflationMustBePositive();
error PercentageOutOfBounds(uint256 percentage);
error NFTManagerNotSet();
error UnauthorizedCaller();
error MustSpecifyNFTType();
error InvalidNFTType(uint16 nftType);
error NativePaymentIsDisabled();

/**
 * @title WizverseNFT
 * @dev ERC721 token with enumerable and burnable features for the Wizverse ecosystem
 */
contract WizverseNFT is ERC721, ERC721Enumerable, ERC721Burnable, Ownable {
    using Address for address payable;

    // Replace Counters with a simple uint256
    uint256 private _nextTokenId;
    
    // Base URI for metadata
    string private _baseTokenURI;
    
    // Core contract address that is always approved to transfer NFTs
    address public coreContract;
    
    // Add this state variable near coreContract:
    address public nftManager;
    bool public nativePaymentsDisabled;
    
    // Component type ranges
    // Wizard types: 0-9
    // Weapon types: 10-19
    // Platform types: 100+
    
    // Metadata structure for components
    struct ComponentMetadata {
        string title;
        string description;
        string animationUrl;
        int256 priceModifier; // Additional price in USD (with 18 decimals), can be negative
    }
    
    // Wizard attributes structure
    struct WizardAttributes {
        uint16 hp;      // Health Points
        uint16 atk;     // Attack Power
        uint16 def;     // Defense
        uint16 spd;     // Speed
        uint32 exp;     // Experience Points
        uint32 score;   // Score
        uint16 hpRe;    // Health Regeneration
        uint16 hpLe;    // Life Endurance
        uint16 respawnCount; // Number of respawns
        uint8 wizardType;  // Wizard Type (0-9)
    }

    struct WeaponAttributes {
            uint16 atkBonus;     // Attack bonus
            uint16 defBonus;     // Defense bonus 
            uint16 spdBonus;     // Speed bonus
            uint8 weaponType;    // Weapon Type (10-19)
            bool isEquipped;     // Whether the weapon is currently equipped
            uint256 equippedTo;  // Token ID of the wizard this weapon is equipped to
        }
        
        struct PlatformAttributes {
            uint16 hpBonus;     // Health bonus
            uint16 hpReBonus;   // Health regeneration bonus
            uint16 defBonus;    // Defense bonus
            uint16 hpLeBonus;   // Life endurance bonus
            uint16 spdBonus;    // Speed bonus
            uint16 atkBonus;    // Attack bonus
            uint16 platformType; // Platform Type (100+)
            bool isEquipped;     // Whether the platform is currently equipped
            uint256 equippedTo;  // Token ID of the wizard this platform is equipped to
        }
    
    // Mapping from token ID to wizard attributes
    mapping(uint256 => WizardAttributes) private _wizardAttributes;

    // Add mapping for weapon attributes
    mapping(uint256 => WeaponAttributes) private _weaponAttributes;

    // Add mapping for platform attributes
    mapping(uint256 => PlatformAttributes) private _platformAttributes;
    
    // Base attributes for wizard types
    mapping(uint8 => WizardAttributes) private _baseAttributes;
    
    // Metadata for component types
    mapping(uint8 => ComponentMetadata) private _wizardMetadata;   // For wizard types 0-9
    mapping(uint8 => ComponentMetadata) private _weaponMetadata;   // For weapon types 10-19
    mapping(uint16 => ComponentMetadata) private _platformMetadata; // For platform types 100+
    
    // Price in USD for base wizard (with 18 decimals)
    uint256 public basePriceUsd;
    
    // Exchange rate from USD to native coin (e.g., BNB, ETH)
    uint256 public priceUsdToNative; // 1 USD = x native tokens (with 18 decimals)
    
    // Mapping of ERC20 token address to its exchange rate with USD
    mapping(address => uint256) public tokenExchangeRates; // 1 USD = x tokens
    
    // Supported payment tokens
    address[] public supportedTokens;
    
    // Treasury address to receive payments
    address public treasury;
    
    // Add these counters to track purchases by type
    // Purchase counters for each type
    mapping(uint8 => uint256) public wizardPurchaseCount;
    mapping(uint8 => uint256) public weaponPurchaseCount;
    mapping(uint16 => uint256) public platformPurchaseCount;

    // Price inflation rates (using fixed point math with 2 decimals: 100 = 1%, 500 = 5%)
    uint256 public wizardPriceInflation = 100; // 1%
    uint256 public weaponPriceInflation = 100; // 1%
    uint256 public platformPriceInflation = 500; // 5%

    // Percentage of payment to send to the Core contract (e.g., 500 means 5.00%)
    uint256 public coreFeePercent; // Value out of 10000

    // Percentage of payment to send to the referrer (e.g., 1000 means 10.00%)
    uint256 public referrerFeePercent = 1000; // Default 10%

    // Events
    event WizardMinted(uint256 indexed tokenId, address indexed owner, uint8 wizardType, uint8 weaponType, uint16 platformType);
    event AttributesUpdated(uint256 indexed tokenId, uint8 wizardType, uint8 weaponType, uint16 platformType);
    event CoreContractUpdated(address indexed previousCore, address indexed newCore);
    event WizardClaimed(address indexed user, uint256 indexed tokenId, uint8 wizardType, uint8 weaponType, uint16 platformType, uint256 paidAmount);
    event ExchangeRateUpdated(address indexed token, uint256 newRate);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ComponentMetadataUpdated(uint16 componentType, string title, string description);
    event PlatformMinted(uint256 indexed tokenId, address indexed owner, uint16 platformType);
    event WeaponMinted(address indexed owner, uint256 indexed tokenId, uint8 weaponType);
    event NativePaymentsDisabledSet(bool disabled);

    // Add external mappings to track equipment relationships
    mapping(uint256 => uint256) public wizardToWeapon;    // wizardId => weaponId
    mapping(uint256 => uint256) public wizardToPlatform;  // wizardId => platformId
    mapping(uint256 => uint256) public weaponToWizard;    // weaponId => wizardId
    mapping(uint256 => uint256) public platformToWizard;  // platformId => wizardId

    // ADD a mapping to track NFT types by token ID
    mapping(uint256 => uint16) private _nftTypes; // TokenId => NFT Type (0-9, 10-19, 100+)

    /**
     * @dev Constructor for the WizverseNFT contract
     * @param _coreContract Address of the core contract
     * @param _treasury Address of the treasury to receive payments
     * @param _initialUsdToNativeRate Initial exchange rate from USD to native coin
     */
    constructor(address _coreContract, address _treasury, uint256 _initialUsdToNativeRate) ERC721("WizverseNFT", "WizNFT") Ownable(msg.sender) {
        // Initialize with default base URI
        _baseTokenURI = "https://openbisea.mypinata.cloud/ipfs/bafybeiafl7ztpxmptbt3tqzlsinzyyqkkr7esoi6ougjuednybntehzfxq/";
        _nextTokenId = 1;
        // Set core contract if provided
        if (_coreContract != address(0)) {
            coreContract = _coreContract;
            emit CoreContractUpdated(address(0), _coreContract);
        }
        
        // Set treasury and exchange rate
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        priceUsdToNative = _initialUsdToNativeRate;

        // Initialize the base price to $1 (with 18 decimals)
        basePriceUsd = 1 * 10**18;

        // Default 10% of primary sales is routed through the Core contract for platform rewards
        coreFeePercent = 1000; // 10% (out of 10000)
    }
    
    /**
     * @dev Set wizard component metadata
     * @param wizardType Wizard type (0-9)
     * @param title Title for this wizard type
     * @param description Description for this wizard type
     * @param animationUrl URL to animated GIF for this wizard type
     * @param priceModifier Additional price in USD for this wizard type
     */
    function setWizardMetadata(
        uint8 wizardType, 
        string memory title, 
        string memory description, 
        string memory animationUrl, 
        int256 priceModifier
    ) external onlyOwner {
        require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
        _wizardMetadata[wizardType] = ComponentMetadata({
            title: title,
            description: description,
            animationUrl: animationUrl,
            priceModifier: priceModifier
        });
        emit ComponentMetadataUpdated(wizardType, title, description);
    }
    
    /**
     * @dev Set weapon component metadata
     * @param weaponType Weapon type (10-19)
     * @param title Title for this weapon type
     * @param description Description for this weapon type
     * @param animationUrl URL to animated GIF for this weapon type
     * @param priceModifier Additional price in USD for this weapon type
     */
    function setWeaponMetadata(
        uint8 weaponType, 
        string memory title, 
        string memory description, 
        string memory animationUrl, 
        int256 priceModifier
    ) external onlyOwner {
        require(weaponType >= 10 && weaponType <= 19, "InvalidWeaponType: Weapon type must be 10-19");
        _weaponMetadata[weaponType] = ComponentMetadata({
            title: title,
            description: description,
            animationUrl: animationUrl,
            priceModifier: priceModifier
        });
        emit ComponentMetadataUpdated(weaponType, title, description);
    }
    
    /**
     * @dev Set platform component metadata
     * @param platformType Platform type (100+)
     * @param title Title for this platform type
     * @param description Description for this platform type
     * @param animationUrl URL to animated GIF for this platform type
     * @param priceModifier Additional price in USD for this platform type
     */
    function setPlatformMetadata(
        uint16 platformType, 
        string memory title, 
        string memory description, 
        string memory animationUrl, 
        int256 priceModifier
    ) external onlyOwner {
        require(platformType >= 100, "InvalidPlatformType: Platform type must be >= 100");
        _platformMetadata[platformType] = ComponentMetadata({
            title: title,
            description: description,
            animationUrl: animationUrl,
            priceModifier: priceModifier
        });
        emit ComponentMetadataUpdated(platformType, title, description);
    }
    
    /**
     * @dev Get wizard component metadata
     * @param wizardType Wizard type (0-9)
     * @return metadata The component metadata
     */
    function getWizardMetadata(uint8 wizardType) external view returns (ComponentMetadata memory) {
        require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
        return _wizardMetadata[wizardType];
    }
    
    /**
     * @dev Get weapon component metadata
     * @param weaponType Weapon type (10-19)
     * @return metadata The component metadata
     */
    function getWeaponMetadata(uint8 weaponType) external view returns (ComponentMetadata memory) {
        require(weaponType >= 10 && weaponType <= 19, "InvalidWeaponType: Weapon type must be 10-19");
        return _weaponMetadata[weaponType];
    }
    
    /**
     * @dev Get platform component metadata
     * @param platformType Platform type (100+)
     * @return metadata The component metadata
     */
    function getPlatformMetadata(uint16 platformType) external view returns (ComponentMetadata memory) {
        require(platformType >= 100, "InvalidPlatformType: Platform type must be >= 100");
        return _platformMetadata[platformType];
    }
    
    /**
     * @dev Calculate total price in USD based on component types, with special handling for skipped components
     * @param wizardType The type of wizard (0-9), or uint8.max to skip wizard
     * @param weaponType The type of weapon (10-19), or uint8.max to skip weapon
     * @param platformType The type of platform (100+), or uint16.max to skip platform
     * @return Price in USD (with 18 decimals)
     */
    function getPriceUsd(uint8 wizardType, uint8 weaponType, uint16 platformType) public view returns (uint256) {
        // Initialize price
        uint256 totalPrice = 0;
        
        // Calculate wizard price if not skipped
        if (wizardType != type(uint8).max) {
            require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
            int256 baseWizardPriceInt = int256(basePriceUsd) + _wizardMetadata[wizardType].priceModifier;
            require(baseWizardPriceInt >= 0);
            if (baseWizardPriceInt < 0) revert PriceCalculationUnderflow();
            uint256 baseWizardPrice = uint256(baseWizardPriceInt);
            uint256 wizardPrice = baseWizardPrice * (10000 + (wizardPurchaseCount[wizardType] * wizardPriceInflation)) / 10000;
            totalPrice += wizardPrice;
        }
        
        // Calculate weapon price if not skipped
        if (weaponType != type(uint8).max) {
            require(weaponType >= 10 && weaponType <= 19, "InvalidWeaponType: Weapon type must be 10-19");
            int256 baseWeaponPriceInt = int256(basePriceUsd) + _weaponMetadata[weaponType].priceModifier;
            require(baseWeaponPriceInt >= 0);
            if (baseWeaponPriceInt < 0) revert InvalidPrice();
            uint256 baseWeaponPrice = uint256(baseWeaponPriceInt);
            uint256 weaponPrice = baseWeaponPrice * (10000 + (weaponPurchaseCount[weaponType] * weaponPriceInflation)) / 10000;
            totalPrice += weaponPrice;
        }
        
        // Calculate platform price if not skipped
        if (platformType != type(uint16).max) {
            require(platformType >= 100, "InvalidPlatformType: Platform type must be >= 100");
            int256 basePlatformPriceInt = int256(basePriceUsd) + _platformMetadata[platformType].priceModifier;
            require(basePlatformPriceInt >= 0);
            if (basePlatformPriceInt < 0) revert InvalidPrice();
            uint256 basePlatformPrice = uint256(basePlatformPriceInt);
            uint256 platformPrice = basePlatformPrice * (10000 + (platformPurchaseCount[platformType] * platformPriceInflation)) / 10000;
            totalPrice += platformPrice;
        }
        
        return totalPrice;
    }
    
    /**
     * @dev Calculate price in native currency based on component types
     * @param wizardType The type of wizard (0-9)
     * @param weaponType The type of weapon (10-19)
     * @param platformType The type of platform (100+)
     * @return Price in native currency (with 18 decimals)
     */
    function getPriceNative(uint8 wizardType, uint8 weaponType, uint16 platformType) public view returns (uint256) {
        uint256 priceUsd = getPriceUsd(wizardType, weaponType, platformType);
        return (priceUsd * priceUsdToNative) / 10**18;
    }
    
    /**
     * @dev Calculate price in token currency based on component types
     * @param wizardType The type of wizard (0-9)
     * @param weaponType The type of weapon (10-19)
     * @param platformType The type of platform (100+)
     * @param token ERC20 token address
     * @return Price in token currency (with token decimals)
     */
    function getPriceToken(uint8 wizardType, uint8 weaponType, uint16 platformType, address token) public view returns (uint256) {
        require(tokenExchangeRates[token] > 0, "TokenNotSupported");
        uint256 priceUsd = getPriceUsd(wizardType, weaponType, platformType);
        uint256 exchangeRate = tokenExchangeRates[token];
        return (priceUsd * exchangeRate) / 10**18;
    }
    
    /**
     * @dev Calculate weapon type and platform type based on wizard type
     * @param wizardType The wizard type (0-9)
     * @return weaponType The calculated weapon type
     * @return platformType The calculated platform type
     */
    function _calculateComponentTypes(uint8 wizardType) internal pure returns (uint8 weaponType, uint16 platformType) {
        require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
        // Deterministic mapping of wizard type to weapon and platform types
        // NOTE: This logic might need to be extended if wizard types 5-9 have different weapon/platform pairings.
        // For now, types 5-9 will behave like type 4.
        if (wizardType == 0) {
            return (10, 100); // Attack weapon, Health platform
        } else if (wizardType == 1) {
            return (11, 100); // Defense weapon, Health platform
        } else if (wizardType == 2) {
            return (12, 100); // Speed weapon, Health platform
        } else if (wizardType == 3) {
            return (10, 101); // Attack weapon, Defense platform
        } else { // wizardType >= 4
            return (11, 102); // Defense weapon, Speed platform
        }
    }

    /**
     * @dev Calculate platform type based on wizard type
     * @param wizardType The wizard type (0-9)
     * @return platformType The calculated platform type
     */
    function _calculatePlatformType(uint8 wizardType) internal pure returns (uint16 platformType) {
        require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
        // Deterministic mapping of wizard type to platform types
        // NOTE: This logic might need to be extended if wizard types 5-9 map to different platform types.
        // For now, types 5-9 will behave like type 4.
        if (wizardType == 0 || wizardType == 1 || wizardType == 2) {
            return 100; // Health platform
        } else if (wizardType == 3) {
            return 101; // Defense platform
        } else { // wizardType >= 4
            return 102; // Speed platform
        }
    }

    /**
     * @dev Calculate wizard attributes based on wizard type
     * @param wizardType The wizard type (0-9)
     * @return Calculated wizard attributes
     */
    function _calculateWizardAttributes(uint8 wizardType) internal view returns (WizardAttributes memory) {
        require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
        
        WizardAttributes memory baseStats = _baseAttributes[wizardType];
        WizardAttributes memory result = baseStats;
        
        // Add base character selection bonus (+5 to all attributes)
        result.hp += 5;
        result.atk += 5;
        result.def += 5;
        result.spd += 5;
        result.hpRe += 5;
        result.hpLe += 5;
        result.respawnCount = 0; // Initialize respawn count
        
        result.wizardType = wizardType;
        
        return result;
    }

    /**
     * @dev Calculate weapon attributes based on weapon type
     * @param weaponType The weapon type (10-19)
     * @return Calculated weapon attributes
     */
    function _calculateWeaponAttributes(uint8 weaponType) internal pure returns (WeaponAttributes memory) {
        require(weaponType >= 10 && weaponType <= 19, "InvalidWeaponType: Weapon type must be 10-19");
        
        // slither-disable-next-line uninitialized-local
        WeaponAttributes memory result;
        
        // Set bonuses based on weapon type
        if (weaponType == 10) { // Attack weapon
            result.atkBonus = 5;
            result.defBonus = 0;
            result.spdBonus = 0;
        } else if (weaponType == 11) { // Defense weapon
            result.atkBonus = 0;
            result.defBonus = 5;
            result.spdBonus = 0;
        } else if (weaponType == 12) { // Speed weapon
            result.atkBonus = 0;
            result.defBonus = 0;
            result.spdBonus = 5;
        }
        
        result.weaponType = weaponType;
        
        return result;
    }

    /**
     * @dev Equip a weapon to a wizard
     * @param wizardId The token ID of the wizard
     * @param weaponId The token ID of the weapon
     */
    function equipWeapon(uint256 wizardId, uint256 weaponId) external {
        address sender = _msgSender();
        require(ownerOf(wizardId) == sender);
        if (ownerOf(wizardId) != sender) revert NotOwnerOfWizard(wizardId);
        require(ownerOf(weaponId) == sender);
        if (ownerOf(weaponId) != sender) revert NotOwnerOfWeapon(weaponId);
        
        require(isWizard(wizardId));
        if (!isWizard(wizardId)) revert InvalidWizardId(wizardId);
        require(isWeapon(weaponId));
        if (!isWeapon(weaponId)) revert InvalidWeaponId(weaponId);
        
        // Unequip any currently equipped weapon from this wizard
        uint256 currentWeapon = wizardToWeapon[wizardId];
        if (currentWeapon != 0) {
            _weaponAttributes[currentWeapon].isEquipped = false;
            _weaponAttributes[currentWeapon].equippedTo = 0;
            weaponToWizard[currentWeapon] = 0;
        }
        
        // Equip the new weapon
        _weaponAttributes[weaponId].isEquipped = true;
        _weaponAttributes[weaponId].equippedTo = wizardId;
        wizardToWeapon[wizardId] = weaponId;
        weaponToWizard[weaponId] = wizardId;
    }

    /**
     * @dev Unequip a weapon from a wizard
     * @param wizardId The token ID of the wizard
     */
    function unequipWeapon(uint256 wizardId) external {
        address sender = _msgSender();
        require(ownerOf(wizardId) == sender);
        if (ownerOf(wizardId) != sender) revert NotOwnerOfWizard(wizardId);
        
        require(isWizard(wizardId));
        if (!isWizard(wizardId)) revert InvalidWizardId(wizardId);
        
        // Get the equipped weapon
        uint256 weaponId = wizardToWeapon[wizardId];
        require(weaponId != 0);
        if (weaponId == 0) revert NoWeaponEquipped(wizardId);
        
        // Unequip the weapon
        _weaponAttributes[weaponId].isEquipped = false;
        _weaponAttributes[weaponId].equippedTo = 0;
        wizardToWeapon[wizardId] = 0;
        weaponToWizard[weaponId] = 0;
    }

    /**
     * @dev Equip a platform to a wizard
     * @param wizardId The token ID of the wizard
     * @param platformId The token ID of the platform
     */
    function equipPlatform(uint256 wizardId, uint256 platformId) external {
        address sender = _msgSender();
        require(ownerOf(wizardId) == sender);
        if (ownerOf(wizardId) != sender) revert NotOwnerOfWizard(wizardId);
        require(ownerOf(platformId) == sender);
        if (ownerOf(platformId) != sender) revert NotOwnerOfPlatform(platformId);
        
        require(isWizard(wizardId));
        if (!isWizard(wizardId)) revert InvalidWizardId(wizardId);
        require(isPlatform(platformId));
        if (!isPlatform(platformId)) revert InvalidPlatformId(platformId);
        
        // Unequip any currently equipped platform from this wizard
        uint256 currentPlatform = wizardToPlatform[wizardId];
        if (currentPlatform != 0) {
            _platformAttributes[currentPlatform].isEquipped = false;
            _platformAttributes[currentPlatform].equippedTo = 0;
            platformToWizard[currentPlatform] = 0;
        }
        
        // Equip the new platform
        _platformAttributes[platformId].isEquipped = true;
        _platformAttributes[platformId].equippedTo = wizardId;
        wizardToPlatform[wizardId] = platformId;
        platformToWizard[platformId] = wizardId;
    }

    /**
     * @dev Unequip a platform from a wizard
     * @param wizardId The token ID of the wizard
     */
    function unequipPlatform(uint256 wizardId) external {
        address sender = _msgSender();
        require(ownerOf(wizardId) == sender);
        if (ownerOf(wizardId) != sender) revert NotOwnerOfWizard(wizardId);
        
        require(isWizard(wizardId));
        if (!isWizard(wizardId)) revert InvalidWizardId(wizardId);
        
        // Get the equipped platform
        uint256 platformId = wizardToPlatform[wizardId];
        require(platformId != 0);
        if (platformId == 0) revert NoPlatformEquipped(wizardId);
        
        // Unequip the platform
        _platformAttributes[platformId].isEquipped = false;
        _platformAttributes[platformId].equippedTo = 0;
        wizardToPlatform[wizardId] = 0;
        platformToWizard[platformId] = 0;
    }

    /**
     * @dev Get the attributes of a specific wizard with equipped weapon bonuses
     * @param tokenId The token ID of the wizard
     * @return hp The wizard's health points
     * @return atk The wizard's attack power
     * @return def The wizard's defense
     * @return spd The wizard's speed
     * @return exp The wizard's experience points
     * @return score The wizard's score
     * @return hpRe The wizard's health regeneration
     * @return hpLe The wizard's life endurance
     * @return wizardType The wizard's type (0-9)
     * @return equippedWeaponId The token ID of equipped weapon (0 = none)
     * @return equippedPlatformId The token ID of equipped platform (0 = none)
     */
    function getWizardWithEquippedStats(uint256 tokenId) external view returns (
        uint16 hp,
        uint16 atk,
        uint16 def,
        uint16 spd,
        uint32 exp,
        uint32 score,
        uint16 hpRe,
        uint16 hpLe,
        uint8 wizardType,
        uint256 equippedWeaponId,
        uint256 equippedPlatformId
    ) {
        require(isWizard(tokenId));
        if (!isWizard(tokenId)) revert InvalidWizardId(tokenId);
        
        WizardAttributes memory attrs = _wizardAttributes[tokenId];
        
        // Get base stats
        hp = attrs.hp;
        atk = attrs.atk;
        def = attrs.def;
        spd = attrs.spd;
        exp = attrs.exp;
        score = attrs.score;
        hpRe = attrs.hpRe;
        hpLe = attrs.hpLe;
        wizardType = attrs.wizardType;
        
        // Get equipped items
        equippedWeaponId = wizardToWeapon[tokenId];
        equippedPlatformId = wizardToPlatform[tokenId];
        
        // Add weapon bonuses if equipped
        if (equippedWeaponId != 0) {
            WeaponAttributes memory weaponAttrs = _weaponAttributes[equippedWeaponId];
            atk += weaponAttrs.atkBonus;
            def += weaponAttrs.defBonus;
            spd += weaponAttrs.spdBonus;
        }
        
        // Add platform bonuses if equipped
        if (equippedPlatformId != 0) {
            PlatformAttributes memory platformAttrs = _platformAttributes[equippedPlatformId];
            hp += platformAttrs.hpBonus;
            hpRe += platformAttrs.hpReBonus;
            def += platformAttrs.defBonus;
            hpLe += platformAttrs.hpLeBonus;
            spd += platformAttrs.spdBonus;
            atk += platformAttrs.atkBonus;
        }
        
        return (hp, atk, def, spd, exp, score, hpRe, hpLe, wizardType, equippedWeaponId, equippedPlatformId);
    }

    /**
     * @dev Get the attributes of a specific weapon
     * @param tokenId The token ID of the weapon
     * @return The weapon's attributes
     */
    function getWeaponAttributes(uint256 tokenId) external view returns (WeaponAttributes memory) {
        require(isWeapon(tokenId));
        if (!isWeapon(tokenId)) revert InvalidWeaponId(tokenId);
        return _weaponAttributes[tokenId];
    }

    /**
     * @dev Get the attributes of a specific platform
     * @param tokenId The token ID of the platform
     * @return The platform's attributes
     */
    function getPlatformAttributes(uint256 tokenId) external view returns (PlatformAttributes memory) {
        require(isPlatform(tokenId));
        if (!isPlatform(tokenId)) revert InvalidPlatformId(tokenId);
        return _platformAttributes[tokenId];
    }

    /**
     * @dev Check if a token is a wizard
     * @param tokenId The token ID to check
     * @return Whether the token is a wizard
     */
    function isWizard(uint256 tokenId) public view returns (bool) {
        return _exists(tokenId) && _nftTypes[tokenId] <= 9;
    }

    /**
     * @dev Check if a token is a weapon
     * @param tokenId The token ID to check
     * @return Whether the token is a weapon
     */
    function isWeapon(uint256 tokenId) public view returns (bool) {
        return _exists(tokenId) && _nftTypes[tokenId] >= 10 && _nftTypes[tokenId] <= 19;
    }

    /**
     * @dev Check if a token is a platform
     * @param tokenId The token ID to check
     * @return Whether the token is a platform
     */
    function isPlatform(uint256 tokenId) public view returns (bool) {
        return _exists(tokenId) && _nftTypes[tokenId] >= 100;
    }

    /**
     * @dev Returns the total wizards minted so far
     */
    function totalWizardsMinted() public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _nextTokenId; i++) {
            if (isWizard(i)) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Returns the total weapons minted so far
     */
    function totalWeaponsMinted() public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _nextTokenId; i++) {
            if (isWeapon(i)) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Returns the total platforms minted so far
     */
    function totalPlatformsMinted() public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _nextTokenId; i++) {
            if (isPlatform(i)) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Mint an NFT based on its type (wizard, weapon, or platform)
     * @param to The recipient address
     * @param nftType The type of NFT:
     *        - 0-9: Wizard types
     *        - 10-19: Weapon types
     *        - 100+: Platform types
     * @return tokenId The ID of the minted token
     */
    function mintNFT(address to, uint16 nftType) public returns (uint256 tokenId) {
        require(msg.sender == nftManager || msg.sender == owner());
        if (msg.sender != nftManager && msg.sender != owner()) revert UnauthorizedCaller();
        tokenId = _nextTokenId++;
        
        if (nftType <= 9) {
            // Mint wizard (types 0-9)
            // Set initial wizard attributes
            WizardAttributes memory wizardAttrs = _calculateWizardAttributes(uint8(nftType));
            _wizardAttributes[tokenId] = wizardAttrs;
            
            // Update purchase counter
            wizardPurchaseCount[uint8(nftType)]++;
            
            // Store the NFT type
            _nftTypes[tokenId] = nftType;
            
            // Mint the NFT
            _safeMint(to, tokenId);
            emit WizardMinted(tokenId, to, uint8(nftType), 0, 0);
        } 
        else if (nftType >= 10 && nftType <= 19) {
            // Mint weapon (types 10-19)
            // Set weapon attributes
            WeaponAttributes memory weaponAttrs = _calculateWeaponAttributes(uint8(nftType));
            weaponAttrs.isEquipped = false;
            weaponAttrs.equippedTo = 0;
            _weaponAttributes[tokenId] = weaponAttrs;
            
            // Update purchase counter
            weaponPurchaseCount[uint8(nftType)]++;
            
            // Store the NFT type
            _nftTypes[tokenId] = nftType;
            
            // Mint the NFT
            _safeMint(to, tokenId);
            emit WeaponMinted(to, tokenId, uint8(nftType));
        }
        else if (nftType >= 100) {
            // Mint platform (types 100+)
            
            // Don't cast to uint8, keep as uint16 to avoid overflow
            PlatformAttributes memory platformAttrs = _calculatePlatformAttributes(nftType);
            platformAttrs.isEquipped = false;
            platformAttrs.equippedTo = 0;
            _platformAttributes[tokenId] = platformAttrs;
            
            // Store the NFT type properly
            _nftTypes[tokenId] = nftType;
            
            // CRITICAL FIX: Add the missing purchase counter update
            platformPurchaseCount[nftType]++;
            
            // Mint the NFT
            _safeMint(to, tokenId);
            emit PlatformMinted(tokenId, to, nftType);
        }
        else {
            revert InvalidNFTType(nftType);
        }
        
        return tokenId;
    }

    /**
     * @dev Batch mint NFTs of various types
     * @param to The recipient address
     * @param nftTypes Array of NFT types to mint (0-9, 10-19, or 100+)
     * @return tokenIds Array of the minted token IDs
     */
    function batchMintNFTs(address to, uint16[] calldata nftTypes) external returns (uint256[] memory tokenIds) {
        require(msg.sender == nftManager || msg.sender == owner());
        if (msg.sender != nftManager && msg.sender != owner()) revert UnauthorizedCaller();
        
        require(nftTypes.length > 0);
        if (nftTypes.length == 0) revert MustSpecifyNFTType();
        tokenIds = new uint256[](nftTypes.length);
        
        for (uint256 i = 0; i < nftTypes.length; i++) {
            tokenIds[i] = mintNFT(to, nftTypes[i]);
        }
        
        return tokenIds;
    }

    /**
     * @dev Calculate platform attributes based on platform type
     * @param platformType The platform type (100+)
     * @return Calculated platform attributes
     */
    function _calculatePlatformAttributes(uint16 platformType) internal pure returns (PlatformAttributes memory) {
        require(platformType >= 100, "InvalidPlatformType: Platform type must be >= 100");
        
        // slither-disable-next-line uninitialized-local
        PlatformAttributes memory result;
        
        // Set bonuses based on platform type
        if (platformType == 100) { // Health platform
            result.hpBonus = 10;
            result.hpReBonus = 2;
            result.defBonus = 0;
            result.hpLeBonus = 0;
            result.spdBonus = 0;
            result.atkBonus = 0;
        } else if (platformType == 101) { // Defense platform
            result.hpBonus = 0;
            result.hpReBonus = 0;
            result.defBonus = 3;
            result.hpLeBonus = 2;
            result.spdBonus = 0;
            result.atkBonus = 0;
        } else if (platformType == 102) { // Speed platform
            result.hpBonus = 0;
            result.hpReBonus = 0;
            result.defBonus = 0;
            result.hpLeBonus = 0;
            result.spdBonus = 4;
            result.atkBonus = 1;
        }
        
        result.platformType = platformType;
        result.isEquipped = false;
        result.equippedTo = 0;
        
        return result;
    }

    /**
     * @dev Update all attributes for a specific wizard. Can only be called by Owner or Core Contract.
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
    function updateWizardAttributes(
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
    ) external {
        require(_exists(tokenId) && isWizard(tokenId));
        if (!_exists(tokenId) || !isWizard(tokenId)) revert InvalidWizardId(tokenId);
        // Allow Owner, Core contract or recognized NFTManager to update attributes.
        address dynamicManager = address(0);
        if (coreContract != address(0)) {
            // attempt to fetch manager from Core – wrapped in try-catch to avoid reverts
            try IWizverseCoreMinimal(coreContract).nftManager() returns (address m) {
                dynamicManager = m;
            } catch {}
        }

        bool authorised = (msg.sender == owner() || msg.sender == coreContract || msg.sender == nftManager || msg.sender == dynamicManager);
        if (!authorised) revert CallerNotOwnerOrCore();
        
        WizardAttributes storage attrs = _wizardAttributes[tokenId];
        attrs.hp = hp;
        attrs.atk = atk;
        attrs.def = def;
        attrs.spd = spd;
        attrs.exp = exp;
        attrs.score = score;
        attrs.hpRe = hpRe;
        attrs.hpLe = hpLe;
        attrs.respawnCount = respawnCount;
        // wizardType remains unchanged
        
        // Emit a simplified event, just noting the update
        emit AttributesUpdated(tokenId, attrs.wizardType, 0, 0); // Keep event signature but pass dummy values for weapon/platform type
    }
    
    /**
     * @dev Get the attributes of a specific wizard
     * @param tokenId The token ID of the wizard
     * @return The wizard's attributes
     */
    function getWizardAttributes(uint256 tokenId) external view returns (WizardAttributes memory) {
        require(_exists(tokenId) && isWizard(tokenId));
        if (!_exists(tokenId) || !isWizard(tokenId)) revert InvalidWizardId(tokenId);
        return _wizardAttributes[tokenId];
    }
    
    /**
     * @dev Update a wizard's experience and score
     * @param tokenId The token ID of the wizard
     * @param expGain Amount of experience to add
     * @param scoreGain Amount of score to add
     */
    function updateProgress(uint256 tokenId, uint32 expGain, uint32 scoreGain) external {
        require(_exists(tokenId));
        if (!_exists(tokenId)) revert NFTDoesNotExist(tokenId);
        require(msg.sender == owner() || msg.sender == coreContract);
        if (msg.sender != owner() && msg.sender != coreContract) revert CallerNotOwnerOrCore();
        
        _wizardAttributes[tokenId].exp += expGain;
        _wizardAttributes[tokenId].score += scoreGain;
    }
    
    /**
     * @dev Set the base URI for token metadata
     * @param newBaseURI The new base URI to set
     */
    function setBaseURI(string memory newBaseURI) public onlyOwner {
        _baseTokenURI = newBaseURI;
    }
    
    /**
     * @dev Returns the base URI for token metadata
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    /**
     * @dev Returns the total tokens minted so far
     */
    function totalMinted() public view returns (uint256) {
        return _nextTokenId;
    }
    
    /**
     * @dev Check if a token exists
     * @param tokenId The token ID to check
     * @return Whether the token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return tokenId < _nextTokenId && _ownerOf(tokenId) != address(0);
    }
    
    // Required overrides for inherited contracts
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    /**
     * @dev Override isApprovedForAll to make the core contract always approved
     */
    function isApprovedForAll(address owner, address operator) public view override(ERC721, IERC721) returns (bool) {
        // Core contract is always approved
        if (operator == coreContract || operator == nftManager) {
            return true;
        }
        
        return super.isApprovedForAll(owner, operator);
    }

    /**
     * @dev Update the purchase counters
     * @param wizardType The type of wizard (0-9)
     * @param weaponType The type of weapon (10-19)
     * @param platformType The type of platform (100+)
     */
    function _updatePurchaseCounters(uint8 wizardType, uint8 weaponType, uint16 platformType) internal {
        wizardPurchaseCount[wizardType]++;
        weaponPurchaseCount[weaponType]++;
        platformPurchaseCount[platformType]++;
    }

    // Add a setter for nftManager (onlyOwner):
    function setNFTManager(address _nftManager) external onlyOwner {
        require(_nftManager != address(0));
        if (_nftManager == address(0)) revert ZeroAddress();
        nftManager = _nftManager;
        // Optionally emit an event for NFTManager update...
    }

    /**
     * @dev Set base attributes for a wizard type
     * @param wizardType Wizard type (0-9)
     * @param hp Base health points
     * @param atk Base attack power
     * @param def Base defense
     * @param spd Base speed
     * @param hpRe Base health regeneration
     * @param hpLe Base life endurance
     */
    function setBaseAttributes(
        uint8 wizardType,
        uint16 hp,
        uint16 atk,
        uint16 def,
        uint16 spd,
        uint16 hpRe,
        uint16 hpLe
    ) external onlyOwner {
        require(wizardType <= 9, "InvalidWizardType: Wizard type must be 0-9");
        
        _baseAttributes[wizardType] = WizardAttributes({
            hp: hp,
            atk: atk,
            def: def,
            spd: spd,
            exp: 0,
            score: 0,
            hpRe: hpRe,
            hpLe: hpLe,
            respawnCount: 0,
            wizardType: wizardType
        });
    }

 

    function tokensOfOwner(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokens = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokens[i] = tokenOfOwnerByIndex(owner, i);
        }
        return tokens;
    }

    /**
     * @dev Set the exchange rate for a token
     * @param token ERC20 token address
     * @param rate Exchange rate (1 USD = rate tokens, with 18 decimals)
     */
    function setTokenExchangeRate(address token, uint256 rate) external onlyOwner {
        require(token != address(0));
        if (token == address(0)) revert ZeroAddress();
        require(rate > 0);
        if (rate == 0) revert PriceMustBePositive();
        
        tokenExchangeRates[token] = rate;
        
        // If this is a new token, add it to the supported tokens list
        bool isNewToken = true;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                isNewToken = false;
                break;
            }
        }
        
        if (isNewToken) {
            supportedTokens.push(token);
        }
        
        emit ExchangeRateUpdated(token, rate);
    }

    /**
     * @dev Batch claim NFTs with native currency
     * @param types Array of NFT types to mint:
     *        - 0-9: Wizard types
     *        - 10-19: Weapon types
     *        - 100+: Platform types
     * @return tokenIds Array of minted token IDs
     */
    function batchClaim(uint16[] calldata types, address referrer, bool isPlatformDistribution) external payable returns (uint256[] memory tokenIds) {
        if (nativePaymentsDisabled) revert NativePaymentIsDisabled();
        require(nftManager != address(0));
        if (nftManager == address(0)) revert NFTManagerNotSet();
        return IWizverseNFTManager(nftManager).batchClaimNFT{value: msg.value}(types, msg.sender, referrer, isPlatformDistribution);
    }

    /**
     * @dev Batch claim NFTs with ERC20 token
     * @param types Array of NFT types to mint:
     *        - 0-9: Wizard types
     *        - 10-19: Weapon types
     *        - 100+: Platform types
     * @param token ERC20 token address
     /// @notice Before calling, the user (msg.sender) MUST approve the NFT Manager contract
     /// (`nftManager` address stored in this contract) to spend the required amount of the specified `token`.
     * @return tokenIds Array of minted token IDs
     */
    function batchClaimToken(uint16[] calldata types, address token, address referrer, bool isPlatformDistribution) external returns (uint256[] memory tokenIds) {
        require(nftManager != address(0));
        if (nftManager == address(0)) revert NFTManagerNotSet();
        return IWizverseNFTManager(nftManager).batchClaimNFTToken(types, token, msg.sender, referrer, isPlatformDistribution);
    }

    /**
     * @dev Override tokenURI to return metadata following the ERC721 Metadata Standard.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId));
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken(tokenId);
        
        uint16 nftType = _nftTypes[tokenId];
        string memory subPath = ""; // Initialize to empty string
        
        if (nftType <= 9) {
            // Wizard type
            subPath = "wizards/";
        } else if (nftType >= 10 && nftType <= 19) {
            // Weapon type
            subPath = "weapons/";
        } else if (nftType >= 100) {
            // Platform type
            subPath = "platforms/";
        } else {
            revert InvalidNFTType(nftType);
        }
        
        // Returns _baseTokenURI + subPath + nftType + ".json"
        return string(abi.encodePacked(_baseTokenURI, subPath, Strings.toString(nftType), ".json"));
    }

    // Add a setter function to update basePriceUsd:
    function setBasePriceUsd(uint256 newPriceUsd) external onlyOwner {
        require(newPriceUsd > 0);
        if (newPriceUsd == 0) revert PriceMustBePositive();
        basePriceUsd = newPriceUsd;
    }

    /**
     * @dev Set the wizard price inflation rate.
     * @param newInflation New inflation rate (using 2 decimals; e.g. 100 = 1%)
     */
    function setWizardPriceInflation(uint256 newInflation) external onlyOwner {
        require(newInflation > 0);
        if (newInflation == 0) revert InflationMustBePositive();
        wizardPriceInflation = newInflation;
    }

    /**
     * @dev Set the weapon price inflation rate.
     * @param newInflation New inflation rate (using 2 decimals; e.g. 100 = 1%)
     */
    function setWeaponPriceInflation(uint256 newInflation) external onlyOwner {
        require(newInflation > 0);
        if (newInflation == 0) revert InflationMustBePositive();
        weaponPriceInflation = newInflation;
    }

    /**
     * @dev Set the platform price inflation rate.
     * @param newInflation New inflation rate (using 2 decimals; e.g. 500 = 5%)
     */
    function setPlatformPriceInflation(uint256 newInflation) external onlyOwner {
        require(newInflation > 0);
        if (newInflation == 0) revert InflationMustBePositive();
        platformPriceInflation = newInflation;
    }

    /**
     * @dev Sets the percentage of the payment that goes to the Core contract.
     * @param _percent The percentage value (e.g., 500 for 5.00%). Must be <= 10000.
     */
    function setCoreFeePercent(uint256 _percent) external onlyOwner {
        require(_percent <= 10000);
        if (_percent > 10000) revert PercentageOutOfBounds(_percent);
        coreFeePercent = _percent;
        // Optionally emit an event
    }

    /**
     * @dev Calculates the health value a wizard should be restored to.
     * This is typically the base HP for the wizard's type plus any initial bonuses.
     * @param tokenId The token ID of the wizard.
     * @return fullHealth The calculated full health value.
     */
    function getRestoredHealth(uint256 tokenId) public view returns (uint16) {
        if (!_exists(tokenId) || !isWizard(tokenId)) revert InvalidWizardId(tokenId);
        WizardAttributes memory attrs = _wizardAttributes[tokenId]; // Get current attributes to find wizardType
        WizardAttributes memory baseStats = _baseAttributes[attrs.wizardType];
        return baseStats.hp + 5; // Matches logic in _calculateWizardAttributes
    }

    // Setter for referrerFeePercent
    function setReferrerFeePercent(uint256 _percent) external onlyOwner {
        if (_percent > 10000) revert PercentageOutOfBounds(_percent);
        referrerFeePercent = _percent;
    }

    /**
     * @dev Returns the NFT type for a given tokenId
     */
    function getNFTTypeById(uint256 tokenId) public view returns (uint16) {
        if (!_exists(tokenId)) revert NFTDoesNotExist(tokenId);
        return _nftTypes[tokenId];
    }

    /**
     * @dev Returns the total native price for a batch of NFT types
     */
    function getBatchPriceNative(uint16[] calldata types) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < types.length; i++) {
            uint16 nftType = types[i];
            if (nftType <= 9) {
                total += getPriceNative(uint8(nftType), type(uint8).max, type(uint16).max);
            } else if (nftType >= 10 && nftType <= 19) {
                total += getPriceNative(type(uint8).max, uint8(nftType), type(uint16).max);
            } else if (nftType >= 100) {
                total += getPriceNative(type(uint8).max, type(uint8).max, nftType);
            } else {
                revert InvalidNFTType(nftType);
            }
        }
        return total;
    }

    /**
     * @dev Returns the total token price for a batch of NFT types
     */
    function getBatchPriceToken(uint16[] calldata types, address token) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < types.length; i++) {
            uint16 nftType = types[i];
            if (nftType <= 9) {
                total += getPriceToken(uint8(nftType), type(uint8).max, type(uint16).max, token);
            } else if (nftType >= 10 && nftType <= 19) {
                total += getPriceToken(type(uint8).max, uint8(nftType), type(uint16).max, token);
            } else if (nftType >= 100) {
                total += getPriceToken(type(uint8).max, type(uint8).max, nftType, token);
            } else {
                revert InvalidNFTType(nftType);
            }
        }
        return total;
    }

    function isSupportedToken(address token) external view returns (bool) {
        return tokenExchangeRates[token] > 0;
    }

    /**
     * @dev Returns an array of all supported ERC20 token addresses.
     * @return tokens Array of supported ERC20 token addresses.
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function setNativePaymentsDisabled(bool _disabled) external onlyOwner {
        nativePaymentsDisabled = _disabled;
        emit NativePaymentsDisabledSet(_disabled);
    }
}