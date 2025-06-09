// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IWizverseNFT.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Define RewardAmount struct here if not already available globally via an import
struct RewardAmount {
    address token; // address(0) for native currency
    uint256 amount;
}

interface IWizverseCore {
    function platformNativeAssets(uint256 platformTokenId) external view returns (uint256);
    function platformTokenAssets(uint256 platformTokenId, address token) external view returns (uint256);
    function distributePlatformFee(uint256 platformTokenId, uint256 amount, address token) external;
    function distributeWinnerRewardsToEscrow(uint256 platformTokenId, address[] calldata winners, uint256[] calldata amounts, address token) external returns (bool);
    function nftContract() external view returns (address);
    function getOriginalOwner(uint256 tokenId) external view returns (address);
    function canRequestRewards(address sender) external view returns (bool canActuallyRequest, RewardAmount[] memory pendingRewards);
    function nativePaymentsDisabled() external view returns (bool);
}
contract WizverseSessions is Ownable {
    using Strings for uint256;
    using Address for address payable;
    using Strings for uint256;

    enum Outcome { None, WinAgainstBots, WinMatch, WinMatchTeam }
    enum SessionType { Solo, Team, Multiplayer }

    struct GameSession {
        uint256 sessionId;
        uint256 platformTokenId;
        address[] players; // full players array for the session
        uint256 timestamp;
        bool active;
        Outcome outcome;
        SessionType sessionType;
        uint256[][] teamCharacterTokenIds;
        uint256[][] teamWeaponTokenIds;
        uint256[] winnerTokenIds; // UPDATED: Store the winning token IDs as an array
        uint256 winTimestamp;     // Store when the win occurred
        address[] winnersWallets; // NEW: Wallets of winners
        uint256[] winnerAmounts;  // NEW: Amounts to pay each winner
        address[] winnersWalletsDistributed; // NEW: Tracks which winners have been paid
        uint256[] winnerDistributedAmounts;  // NEW: Amounts that have been paid to winners
        address winnerToken;      // NEW: Token address for winner payment (address(0) for native)
        uint256 percentPayWinner; // NEW: Percentage to pay winners (10000 = 100%)
        bool winnerDistribution;  // NEW: Tracks if winners have been paid, initially false
    }
    
    uint256 public sessionCount;
    mapping(uint256 => GameSession) public gameSessions;
    // Duplicate prevention mapping (hash => timestamp)
    mapping(bytes32 => uint256) internal _recentSessionAttempts;
    uint256 public constant SESSION_COOLDOWN = 2 minutes;
    
    // Minimum duration (in seconds) a player must be signed in.
    uint256 public constant SIGNIN_MIN_TIME = 1 seconds;
    
    // Event emitted when a session is updated
    event SessionUpdated(
        uint256 indexed sessionId, 
        uint8 outcome, 
        uint256[] winnerTokenIds, 
        bool completed, 
        address[] winnersWallets, 
        uint256[] winnerAmounts
    );
    
    // Event for session creation, now emitted by Sessions
    event SessionCreated(
        uint256 indexed sessionId,
        SessionType sessionType,
        uint256 indexed platformTokenId,
        address[] players,
        uint256[][] teamCharacterTokenIds,
        uint256[][] teamWeaponTokenIds,
        uint256 timestamp
    );
    
    // Event emitted when distribution fails
    event DistributionFailed(
        uint256 indexed sessionId,
        uint256 platformTokenId,
        address[] winnersWallets,
        uint256[] winnerAmounts
    );
    
    // Event emitted when distribution error occurs
    event DistributionError(
        uint256 indexed sessionId,
        bytes reason
    );
    
    // Reference to NFT manager (if needed for further validation)
    address public nftManager;
    // Core contract address allowed to call these functions.
    address public core;
    
    // Default percentage of platform assets to pay to winners (10000 = 100%)
    uint256 public percentPayWinner = 100; // Default 1%
    
    // Event emitted when percentPayWinner is updated
    event PercentPayWinnerUpdated(uint256 oldPercent, uint256 newPercent);
    
    // State variables to track wallets and amounts waiting for distribution
    address[] public walletsWaitingForDistribution;
    uint256[] public amountsWaitingForDistribution;
    address[] public tokensWaitingForDistribution;
    uint256[] public sessionIdsWaitingForDistribution;
    
    // Event emitted when a reward claim is confirmed
    event RewardClaimConfirmed(uint256 indexed sessionId, address indexed wallet, uint256 amount);

    // Allow contract to receive Ether
    receive() external payable {}

    // New modifier: only callable by the Core contract.
    modifier onlyCore() {
        require(msg.sender == core, "WizverseSessions: caller is not Core");
        _;
    }
    
    /**
     * @dev Constructor.
     * @param _nftManager Address of the NFT manager.
     */
    constructor(address _nftManager) Ownable(msg.sender) {
        require(_nftManager != address(0), "WizverseSessions: invalid nftManager address");
        nftManager = _nftManager;
    }
    
    /**
     * @dev Set the Core contract address. Only callable by the owner.
     * @param _core Address of the Core contract.
     */
    function setCore(address _core) external onlyOwner {
        require(_core != address(0), "WizverseSessions: invalid core address");
        core = _core;
    }
    
    /**
     * @dev Set the percentage of platform assets to pay to winners
     * @param _percentPayWinner New percentage (10000 = 100%)
     */
    function setPercentPayWinner(uint256 _percentPayWinner) external onlyOwner {
        require(_percentPayWinner <= 10000, "WizverseSessions: percentage must be <= 10000");
        uint256 oldPercent = percentPayWinner;
        percentPayWinner = _percentPayWinner;
        emit PercentPayWinnerUpdated(oldPercent, _percentPayWinner);
    }
    
    /**
     * @dev Internal helper to check that each player's sign-in timestamp is older than SIGNIN_MIN_TIME.
     * Reverts if a player has not signed in or if the sign-in was too recent.
     */
    function _checkPlayersSignedIn(address[] memory players) internal view {
        for (uint256 i = 0; i < players.length; i++) {
            uint256 signTime = _signInTimestamps[players[i]];
            require(
                signTime != 0,
                string(abi.encodePacked(
                    "Player ",
                    Strings.toHexString(uint160(players[i]), 20),
                    " has not signed in"
                ))
            );
            require(
                block.timestamp - signTime > SIGNIN_MIN_TIME,
                string(abi.encodePacked(
                    "Player ",
                    Strings.toHexString(uint160(players[i]), 20),
                    " sign-in too recent"
                ))
            );
        }
    }
    
    /**
     * @dev Helper function to check if there's an active session with the same parameters.
     * @param paramsHash The hash of the session parameters
     * @return exists True if an active session with the same parameters exists
     * @return sessionId The ID of the matching active session (0 if none found)
     */
    function _hasActiveSessionWithParams(bytes32 paramsHash) internal view returns (bool exists, uint256 sessionId) {
        for (uint256 i = 1; i <= sessionCount; i++) {
            GameSession storage session = gameSessions[i];
            if (session.active) {
                // For each active session, compute its parameters hash based on session type
                bytes memory sessionParams = "";
                
                if (session.sessionType == SessionType.Solo) {
                    // For Solo sessions, extract the first (and only) character and weapon
                    uint256 characterTokenId = session.teamCharacterTokenIds[0][0];
                    uint256 weaponTokenId = session.teamWeaponTokenIds[0][0];
                    address player = session.players[0];
                    sessionParams = abi.encode(characterTokenId, weaponTokenId, session.platformTokenId, player);
                } 
                else if (session.sessionType == SessionType.Team) {
                    // For Team sessions, use the full team arrays and players
                    sessionParams = abi.encode(
                        session.teamCharacterTokenIds[0], 
                        session.teamWeaponTokenIds[0], 
                        session.platformTokenId, 
                        session.players
                    );
                }
                else if (session.sessionType == SessionType.Multiplayer) {
                    // For Multiplayer sessions, use both teams' arrays and players
                    sessionParams = abi.encode(
                        session.teamCharacterTokenIds[0],
                        session.teamWeaponTokenIds[0],
                        session.teamCharacterTokenIds[1],
                        session.teamWeaponTokenIds[1],
                        session.platformTokenId,
                        session.players
                    );
                }
                
                // Check if the computed hash matches the provided hash
                if (keccak256(sessionParams) == paramsHash) {
                    return (true, i);
                }
            }
        }
        return (false, 0);
    }
    
    /**
     * @dev Check if a platform has any active sessions
     * @param platformTokenId The platform token ID to check
     * @return hasActiveSessions True if the platform has active sessions
     * @return activeSessionCount The number of active sessions for this platform
     */
    function checkPlatformHasActiveSessions(uint256 platformTokenId) external view returns (bool hasActiveSessions, uint256 activeSessionCount) {
        activeSessionCount = 0;
        
        for (uint256 i = 1; i <= sessionCount; i++) {
            // slither-disable-next-line incorrect-equality
            if (gameSessions[i].active && gameSessions[i].platformTokenId == platformTokenId) {
                activeSessionCount++;
            }
        }
        
        return (activeSessionCount > 0, activeSessionCount);
    }

    /**
     * @dev Get total number of sessions associated with a platform (both active and inactive)
     * @param platformTokenId The platform token ID
     * @return totalCount The total number of sessions for this platform
     */
    function getPlatformTotalSessions(uint256 platformTokenId) external view returns (uint256 totalCount) {
        totalCount = 0;
        for (uint256 i = 1; i <= sessionCount; i++) {
            // slither-disable-next-line incorrect-equality
            if (gameSessions[i].platformTokenId == platformTokenId) {
                totalCount++;
            }
        }
        return totalCount;
    }

    /**
     * @dev Helper function to check for active duplicates and increment session counter.
     * Checks if an active session exists with the exact same platform, type, players, characters, and weapons.
     * @param sessionType The type of session being created
     * @param teamCharacterTokenIds Character tokens for the session (used for comparison)
     * @param teamWeaponTokenIds Weapon tokens for the session (used for comparison)
     * @param platformTokenId Platform token ID (used for comparison)
     * @param players Player addresses (used for comparison)
     */
    function _createSession(
        SessionType sessionType,
        uint256[][] memory teamCharacterTokenIds, // Use consistent 2D array format
        uint256[][] memory teamWeaponTokenIds,     // Use consistent 2D array format
        uint256 platformTokenId,
        address[] memory players // players data is used for comparison loop
    ) internal returns (uint256 sessionId) {

        // Check for active duplicate sessions with exact parameters
        for (uint256 i = 1; i <= sessionCount; i++) {
            GameSession storage existingSession = gameSessions[i];

            // 1. Check if active
            if (!existingSession.active) {
                continue; // Skip inactive sessions
            }

            // 2. Check platform match
            if (existingSession.platformTokenId != platformTokenId) {
                continue;
            }

            // 3. Check session type match
            if (existingSession.sessionType != sessionType) {
                continue;
            }

            // 4. Check players match
            if (!_areAddressesEqual(existingSession.players, players)) {
                continue;
            }

            // 5. Check character and weapon token IDs match based on type
            bool tokensMatch = false;
            if (sessionType == SessionType.Solo) {
                tokensMatch = (existingSession.teamCharacterTokenIds[0][0] == teamCharacterTokenIds[0][0] &&
                               existingSession.teamWeaponTokenIds[0][0] == teamWeaponTokenIds[0][0]);
            } else if (sessionType == SessionType.Team) {
                tokensMatch = (_areUintArraysEqual(existingSession.teamCharacterTokenIds[0], teamCharacterTokenIds[0]) &&
                               _areUintArraysEqual(existingSession.teamWeaponTokenIds[0], teamWeaponTokenIds[0]));
            } else { // Multiplayer
                 tokensMatch = (_areUintArraysEqual(existingSession.teamCharacterTokenIds[0], teamCharacterTokenIds[0]) &&
                               _areUintArraysEqual(existingSession.teamWeaponTokenIds[0], teamWeaponTokenIds[0]) &&
                               _areUintArraysEqual(existingSession.teamCharacterTokenIds[1], teamCharacterTokenIds[1]) &&
                               _areUintArraysEqual(existingSession.teamWeaponTokenIds[1], teamWeaponTokenIds[1]));
            }

            if (!tokensMatch) {
                continue;
            }

            // 6. If all checks pass, a duplicate active session exists
            revert(string(abi.encodePacked("DUPLICATE: Active session exists with same parameters. Session ID: ", existingSession.sessionId.toString())));
        }

        // // Optional: Anti-spam check (can be re-enabled if needed)
        // bytes32 paramsHash = _calculateSessionParamsHash(sessionType, teamCharacterTokenIds, teamWeaponTokenIds, platformTokenId, players);
        // if (_recentSessionAttempts[paramsHash] > 0 && block.timestamp <= _recentSessionAttempts[paramsHash] + SESSION_COOLDOWN) {
        //     uint256 timeLeft = _recentSessionAttempts[paramsHash] + SESSION_COOLDOWN - block.timestamp;
        //     require(false, string(abi.encodePacked("Session attempt too recent. Try again in ", timeLeft.toString(), " seconds")));
        // }
        // _recentSessionAttempts[paramsHash] = block.timestamp;

        sessionCount++;
        return sessionCount;
    }

    /**
     * @dev Internal helper to calculate the parameter hash for any session type. (Can be kept for anti-spam or removed if unused)
     */
    function _calculateSessionParamsHash(
        SessionType sessionType,
        uint256[][] memory teamCharacterTokenIds,
        uint256[][] memory teamWeaponTokenIds,
        uint256 platformTokenId,
        address[] memory players
    ) internal pure returns (bytes32) {
        if (sessionType == SessionType.Solo) {
            // Solo: Use first element of the nested arrays
            return keccak256(abi.encode(teamCharacterTokenIds[0][0], teamWeaponTokenIds[0][0], platformTokenId, players[0]));
        } else if (sessionType == SessionType.Team) {
            // Team: Use first team's arrays
            return keccak256(abi.encode(teamCharacterTokenIds[0], teamWeaponTokenIds[0], platformTokenId, players));
        } else { // Multiplayer
            // Multiplayer: Use both teams' arrays
            return keccak256(abi.encode(teamCharacterTokenIds[0], teamWeaponTokenIds[0], teamCharacterTokenIds[1], teamWeaponTokenIds[1], platformTokenId, players));
        }
    }

    /// @dev Internal helper to validate team session require statements.
    function _validateTeamSession(
        uint256[] calldata teamCharacterTokenIds,
        uint256[] calldata teamWeaponTokenIds,
        string memory errorPrefix
    ) internal pure {
        require(teamCharacterTokenIds.length > 0, string(abi.encodePacked(errorPrefix, ": no character tokens provided")));
        require(teamWeaponTokenIds.length > 0, string(abi.encodePacked(errorPrefix, ": no weapon tokens provided")));
        require(teamCharacterTokenIds.length == teamWeaponTokenIds.length, string(abi.encodePacked(errorPrefix, ": mismatched team arrays")));
    }
    
    /// @dev Internal helper to validate multiplayer session require statements.
    function _validateMultiplayerSession(
        uint256[] calldata team1CharacterTokenIds,
        uint256[] calldata team1WeaponTokenIds,
        uint256[] calldata team2CharacterTokenIds,
        uint256[] calldata team2WeaponTokenIds,
        address[] calldata players
    ) internal pure {
        _validateTeamSession(team1CharacterTokenIds, team1WeaponTokenIds, "Multiplayer session Team 1");
        _validateTeamSession(team2CharacterTokenIds, team2WeaponTokenIds, "Multiplayer session Team 2");
        require(players.length == 2, "Multiplayer session: exactly 2 players required");
    }
    
    /**
     * @dev Create a new solo session.
     * The solo session is stored by wrapping the individual token IDs in nested arrays.
     */
    function createSessionSolo(
        uint256 characterTokenId,
        uint256 weaponTokenId,
        uint256 platformTokenId,
        address player
    )
        external onlyCore
        returns (uint256 sessionId)
    {
        address[] memory soloPlayer = _toArray(player);
        // _checkPlayersSignedIn(soloPlayer);
        
        // Wrap single tokens in nested arrays for consistency
        uint256[][] memory teamCharacters = new uint256[][](1);
        teamCharacters[0] = new uint256[](1);
        teamCharacters[0][0] = characterTokenId;
        
        uint256[][] memory teamWeapons = new uint256[][](1);
        teamWeapons[0] = new uint256[](1);
        teamWeapons[0][0] = weaponTokenId;

        // Call _createSession without hash
        sessionId = _createSession(SessionType.Solo, teamCharacters, teamWeapons, platformTokenId, soloPlayer);
        
        gameSessions[sessionId] = GameSession({
            sessionId: sessionId,
            platformTokenId: platformTokenId,
            players: soloPlayer,
            timestamp: block.timestamp,
            active: true,
            outcome: Outcome.None,
            sessionType: SessionType.Solo,
            teamCharacterTokenIds: teamCharacters, // Use the prepared 2D array
            teamWeaponTokenIds: teamWeapons,       // Use the prepared 2D array
            winnerTokenIds: new uint256[](0),
            winTimestamp: 0,
            winnersWallets: new address[](0),
            winnerAmounts: new uint256[](0),
            winnersWalletsDistributed: new address[](0),
            winnerDistributedAmounts: new uint256[](0),
            winnerToken: address(0),
            percentPayWinner: 0,
            winnerDistribution: false
        });

        emit SessionCreated(
            sessionId,
            SessionType.Solo,
            platformTokenId,
            soloPlayer,
            teamCharacters,
            teamWeapons,
            block.timestamp
        );
        return sessionId;
    }
    
    /**
     * @dev Create a new team session.
     * The passed 1D token ID arrays are wrapped into 2D arrays and the full players list is recorded.
     */
    function createSessionTeam(
        uint256[] calldata teamCharacterTokenIds,
        uint256[] calldata teamWeaponTokenIds,
        uint256 platformTokenId,
        address[] calldata players
    )
        external onlyCore
        returns (uint256 sessionId)
    {
        require(players.length > 0, "Team session: at least one player required");
        _validateTeamSession(teamCharacterTokenIds, teamWeaponTokenIds, "Team session");
        // _checkPlayersSignedIn(players);
        
        // Wrap provided 1D token arrays into 2D arrays for consistency
        uint256[][] memory teamCharacters = new uint256[][](1);
        teamCharacters[0] = teamCharacterTokenIds;
        
        uint256[][] memory teamWeapons = new uint256[][](1);
        teamWeapons[0] = teamWeaponTokenIds;

        // Call _createSession without hash
        sessionId = _createSession(SessionType.Team, teamCharacters, teamWeapons, platformTokenId, players);
                
        gameSessions[sessionId] = GameSession({
            sessionId: sessionId,
            platformTokenId: platformTokenId,
            players: players,
            timestamp: block.timestamp,
            active: true,
            outcome: Outcome.None,
            sessionType: SessionType.Team,
            teamCharacterTokenIds: teamCharacters, // Use the prepared 2D array
            teamWeaponTokenIds: teamWeapons,       // Use the prepared 2D array
            winnerTokenIds: new uint256[](0),
            winTimestamp: 0,
            winnersWallets: new address[](0),
            winnerAmounts: new uint256[](0),
            winnersWalletsDistributed: new address[](0),
            winnerDistributedAmounts: new uint256[](0),
            winnerToken: address(0),
            percentPayWinner: 0,
            winnerDistribution: false
        });

        emit SessionCreated(
            sessionId,
            SessionType.Team,
            platformTokenId,
            players,
            teamCharacters,
            teamWeapons,
            block.timestamp
        );
        return sessionId;
    }
    
    /**
     * @dev Create a new multiplayer session.
     * Expects exactly two teams and exactly 2 players.
     */
    function createSessionMultiplayer(
        uint256[] calldata team1CharacterTokenIds,
        uint256[] calldata team1WeaponTokenIds,
        uint256[] calldata team2CharacterTokenIds,
        uint256[] calldata team2WeaponTokenIds,
        uint256 platformTokenId,
        address[] calldata players
    )
        external onlyCore
        returns (uint256 sessionId)
    {
        _validateMultiplayerSession(team1CharacterTokenIds, team1WeaponTokenIds, team2CharacterTokenIds, team2WeaponTokenIds, players);
        // _checkPlayersSignedIn(players);
        
        // Create two-element arrays for teams for consistency
        uint256[][] memory teamsCharacters = new uint256[][](2);
        teamsCharacters[0] = team1CharacterTokenIds;
        teamsCharacters[1] = team2CharacterTokenIds;
        
        uint256[][] memory teamsWeapons = new uint256[][](2);
        teamsWeapons[0] = team1WeaponTokenIds;
        teamsWeapons[1] = team2WeaponTokenIds;

        // Call _createSession without hash
        sessionId = _createSession(SessionType.Multiplayer, teamsCharacters, teamsWeapons, platformTokenId, players);
        
        gameSessions[sessionId] = GameSession({
            sessionId: sessionId,
            platformTokenId: platformTokenId,
            players: players,
            timestamp: block.timestamp,
            active: true,
            outcome: Outcome.None,
            sessionType: SessionType.Multiplayer,
            teamCharacterTokenIds: teamsCharacters, // Use the prepared 2D array
            teamWeaponTokenIds: teamsWeapons,       // Use the prepared 2D array
            winnerTokenIds: new uint256[](0),
            winTimestamp: 0,
            winnersWallets: new address[](0),
            winnerAmounts: new uint256[](0),
            winnersWalletsDistributed: new address[](0),
            winnerDistributedAmounts: new uint256[](0),
            winnerToken: address(0),
            percentPayWinner: 0,
            winnerDistribution: false
        });

        emit SessionCreated(
            sessionId,
            SessionType.Multiplayer,
            platformTokenId,
            players,
            teamsCharacters,
            teamsWeapons,
            block.timestamp
        );
        return sessionId;
    }
    
    /**
     * @dev Update a session's outcome.
     * Can be used to mark a session as completed.
     * @param sessionId The ID of the session to update
     * @param outcome The new outcome value
     * @param winnerTokenIds The token IDs of the winners (if applicable)
     * @param completed Boolean indicating if the session is definitively completed
     */
    function updateSession(uint256 sessionId, uint8 outcome, uint256[] calldata winnerTokenIds, bool completed) external onlyCore {
        // --- CHECKS ---
        require(sessionId > 0 && sessionId <= sessionCount, "Invalid sessionId");
        GameSession storage session = gameSessions[sessionId];
        require(session.active, "Session is not active");
        
        // --- EFFECTS --- 
        session.outcome = Outcome(outcome);
        // Initialize local arrays to prevent Slither warning
        // address[] memory winnersWallets = new address[](0); // Will be populated specifically
        // uint256[] memory winnerAmounts = new uint256[](0); // Will be populated specifically
        bool shouldDistribute = false;   // Flag to indicate if distribution should happen
        // uint256 validWinnerCount = 0;    // Track valid winners // Replaced by dynamic sizing or direct use

        // Determine winners and calculate amounts if there is a win outcome
        if (outcome > 0 && winnerTokenIds.length > 0) {
            address nftAddr = IWizverseCore(core).nftContract();
            require(nftAddr != address(0), "NFT contract not set in Core");
            IWizverseNFT nft = IWizverseNFT(nftAddr);
            address rewardToken = address(0);

            address[] memory tempWinnersWallets = new address[](winnerTokenIds.length);
            uint256[] memory tempCharacterTokenIds = new uint256[](winnerTokenIds.length); // To store corresponding char ID for respawn check
            uint256[] memory tempShareFactors = new uint256[](winnerTokenIds.length);
            uint256 currentValidWinnerCount = 0;
            uint256 totalShareFactors = 0;

            for (uint256 i = 0; i < winnerTokenIds.length; i++) {
                uint256 currentTokenId = winnerTokenIds[i];
                address originalOwner = address(0); // Initialize to prevent uninitialized-local warning
                bool isTokWizard = false;
                uint16 respawnCount = 9; // Default to max penalty (0 share factor)

                try IWizverseCore(core).getOriginalOwner(currentTokenId) returns (address owner) {
                    originalOwner = owner;
                } catch {
                    originalOwner = address(0);
                }

                if (originalOwner != address(0)) {
                    try nft.isWizard(currentTokenId) returns (bool r) {
                        isTokWizard = r;
                    } catch {
                        // isTokWizard remains false
                    }

                    if (isTokWizard) {
                        try nft.getWizardAttributes(currentTokenId) returns (WizardAttributes memory attrs) {
                            respawnCount = attrs.respawnCount;
                        } catch {
                            // respawnCount remains 9 (max penalty) if attributes can't be fetched
                        }

                        tempWinnersWallets[currentValidWinnerCount] = originalOwner;
                        tempCharacterTokenIds[currentValidWinnerCount] = currentTokenId; // Storing for reference if needed

                        if (respawnCount >= 9) {
                            tempShareFactors[currentValidWinnerCount] = 0;
                        } else {
                            tempShareFactors[currentValidWinnerCount] = 9 - respawnCount; // Factor from 0 to 9
                        }
                        totalShareFactors += tempShareFactors[currentValidWinnerCount];
                        currentValidWinnerCount++;
                    }
                }
            }

            // Now, populate session.winnersWallets and session.winnerAmounts
            session.winnersWallets = new address[](currentValidWinnerCount);
            session.winnerAmounts = new uint256[](currentValidWinnerCount);

            if (currentValidWinnerCount > 0 && totalShareFactors > 0) {
                bool nativeDisabled = IWizverseCore(core).nativePaymentsDisabled();
                uint256 platformAssets = 0;

                if (nativeDisabled) {
                    address[] memory supportedTokens = nft.getSupportedTokens();
                    require(supportedTokens.length > 0, "No supported tokens for rewards");
                    rewardToken = supportedTokens[0];
                    platformAssets = IWizverseCore(core).platformTokenAssets(session.platformTokenId, rewardToken);
                } else {
                    platformAssets = IWizverseCore(core).platformNativeAssets(session.platformTokenId);
                }

                if (platformAssets > 0) {
                    // Combine calculations to minimize precision loss from intermediate divisions
                    // Ensure totalShareFactors and (10000 * totalShareFactors) are not zero
                    if (platformAssets > 0 && percentPayWinner > 0 && totalShareFactors > 0) { // Check individual components too
                        for (uint256 k = 0; k < currentValidWinnerCount; k++) {
                            session.winnersWallets[k] = tempWinnersWallets[k];
                            // Distribute proportionally to avoid precision loss from divide-before-multiply
                            // Ensure tempShareFactors[k] is used from the populated part of the array
                            session.winnerAmounts[k] = (platformAssets * percentPayWinner * tempShareFactors[k]) / (10000 * totalShareFactors);
                        }
                        shouldDistribute = true; 
                    } else { // One of the multiplicative factors for rewards is zero, or no shares
                        for (uint256 k = 0; k < currentValidWinnerCount; k++) {
                            session.winnersWallets[k] = tempWinnersWallets[k];
                            session.winnerAmounts[k] = 0;
                        }
                        // shouldDistribute remains false, as no amounts to distribute
                    }
                } else { // platformAssets is 0
                    for (uint256 k = 0; k < currentValidWinnerCount; k++) {
                        session.winnersWallets[k] = tempWinnersWallets[k];
                        session.winnerAmounts[k] = 0;
                    }
                    // shouldDistribute remains false
                }
            } else { // No valid winners with share factors, or no valid winners at all
                // session.winnersWallets and session.winnerAmounts are already new empty/zeroed arrays
                // shouldDistribute remains false
            }
            // Store calculated winner info in session state *before* external call
            session.winnerToken = rewardToken;
            session.percentPayWinner = percentPayWinner; // Store the global one used for this calculation
        }


        // Set winner token IDs if provided (even if no distribution)
        if (winnerTokenIds.length > 0) {
            session.winnerTokenIds = winnerTokenIds;
        }
        
        // Record win timestamp if there's a win outcome
        if (outcome > 0) {
            session.winTimestamp = block.timestamp;
        }
        
        // Mark session as inactive if completed
        if (completed) {
             session.active = false;
        }

        // Emit event *after* state changes, *before* interaction
        emit SessionUpdated(
            sessionId, 
            outcome, 
            session.winnerTokenIds, // Use session state (original list of declared winners)
            completed, 
            session.winnersWallets, // Use session state (final list of actual payees)
            session.winnerAmounts   // Use session state (final adjusted amounts)
        );

        // --- INTERACTIONS --- 
        // Perform distribution if calculated earlier and there are amounts to distribute
        if (shouldDistribute) {
            // Check if there's actually anything to send (sum of winnerAmounts > 0)
            uint256 totalAmountToDistribute = 0;
            for(uint256 k=0; k < session.winnerAmounts.length; k++){
                totalAmountToDistribute += session.winnerAmounts[k];
            }

            if (totalAmountToDistribute > 0) {
                try IWizverseCore(core).distributeWinnerRewardsToEscrow(
                    session.platformTokenId,
                    session.winnersWallets, 
                    session.winnerAmounts,  
                    session.winnerToken
                ) returns (bool success) {
                    if (!success) {
                        emit DistributionFailed(sessionId, session.platformTokenId, session.winnersWallets, session.winnerAmounts);
                    }
                } catch (bytes memory reason) {
                    emit DistributionError(sessionId, reason);
                }
            } else {
                // Optionally emit an event here if distribution was skipped due to all winner amounts being zero
                // For example: emit DistributionSkipped(sessionId, "All winner amounts zero after respawn penalty");
            }
        }
    }
    
    // Internal helper function to convert an address to an array with one element.
    function _toArray(address addr) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }
    
    // --- Sign-In Tracking ---
    mapping(address => uint256) private _signInTimestamps;
    
    /**
     * @dev Records the sign-in timestamp for a given wallet.
     * Only callable by the Core contract.
     * @param wallet The wallet address to record the sign-in for.
     */
    function createSignin(address wallet) external onlyCore {
        _signInTimestamps[wallet] = block.timestamp;
        // Optionally emit an event.
    }
    
    /**
     * @dev Returns the sign-in timestamp for a given wallet.
     * @param wallet The wallet address to query.
     * @return timestamp The timestamp when the wallet signed in.
     */
    function getSigninTimestamp(address wallet) external view returns (uint256) {
        return _signInTimestamps[wallet];
    }

    /**
     * @dev Get active sessions for a specified player. If player address is zero, returns all active sessions.
     * @param player The address of the player. Use address(0) to get all active sessions.
     * @param offset The starting index for pagination.
     * @param limit The maximum number of sessions to return.
     * @return sessionIds An array of active session IDs.
     */
    function getActiveSessions(address player, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        // First, count matching sessions to allocate proper array size
        uint256 count = 0;
        uint256 matchingCount = 0;
        
        for (uint256 i = 1; i <= sessionCount; i++) {
            if (gameSessions[i].active) {
                if (player == address(0) || _containsPlayer(gameSessions[i].players, player)) {
                    matchingCount++;
                    if (matchingCount > offset && count < limit) {
                        count++;
                    }
                }
            }
        }
        
        // Allocate array of proper size
        uint256[] memory activeSessionIds = new uint256[](count);
        
        // Fill array with session IDs
        count = 0;
        matchingCount = 0;
        
        for (uint256 i = 1; i <= sessionCount; i++) {
            if (gameSessions[i].active) {
                if (player == address(0) || _containsPlayer(gameSessions[i].players, player)) {
                    matchingCount++;
                    if (matchingCount > offset && count < limit) {
                        activeSessionIds[count] = i;
                        count++;
                    }
                }
            }
        }
        
        return activeSessionIds;
    }

    /**
     * @dev Helper function to check if a player exists in an array of players.
     */
    function _containsPlayer(address[] memory players, address player) internal pure returns (bool) {
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == player) {
                return true;
            }
        }
        return false;
    }

    // --- NEW: Session information retrieval ---
    /**
     * @dev Get detailed information about a session
     * @param sessionId The ID of the session to query
     * @return id The session ID
     * @return platformTokenId The platform token ID used for this session
     * @return timestamp The timestamp when the session was created
     * @return players Array of player addresses
     * @return active Whether the session is active
     * @return outcome The current outcome of the session
     * @return winnerTokenIds The token IDs of the winners (if applicable)
     * @return winTimestamp The timestamp when the win occurred (if applicable)
     */
    function getSessionInfo(uint256 sessionId) external view returns (
        uint256 id,
        uint256 platformTokenId,
        uint256 timestamp,
        address[] memory players,
        bool active,
        uint8 outcome,
        uint256[] memory winnerTokenIds,
        uint256 winTimestamp
    ) {
        require(sessionId > 0 && sessionId <= sessionCount, "WizverseSessions: invalid sessionId");
        
        GameSession storage session = gameSessions[sessionId];
        
        return (
            session.sessionId,
            session.platformTokenId,
            session.timestamp,
            session.players,
            session.active,
            uint8(session.outcome),
            session.winnerTokenIds,
            session.winTimestamp
        );
    }

    /**
     * @dev Get active sessions for a specific platform
     * @param platformTokenId The platform token ID
     * @param offset The starting index for pagination
     * @param limit The maximum number of sessions to return
     * @return sessionIds An array of active session IDs for the platform
     */
    function getActivePlatformSessions(uint256 platformTokenId, uint256 offset, uint256 limit) external view returns (uint256[] memory sessionIds) {
        // First, count matching sessions to allocate proper array size
        uint256 count = 0;
        uint256 matchingCount = 0;
        
        for (uint256 i = 1; i <= sessionCount; i++) {
            // slither-disable-next-line incorrect-equality
            if (gameSessions[i].active && gameSessions[i].platformTokenId == platformTokenId) {
                matchingCount++;
                if (matchingCount > offset && count < limit) {
                    count++;
                }
            }
        }
        
        // Allocate array of proper size
        sessionIds = new uint256[](count);
        
        // Fill array with session IDs
        count = 0;
        matchingCount = 0;
        
        for (uint256 i = 1; i <= sessionCount; i++) {
            // slither-disable-next-line incorrect-equality
            if (gameSessions[i].active && gameSessions[i].platformTokenId == platformTokenId) {
                matchingCount++;
                if (matchingCount > offset && count < limit) {
                    sessionIds[count] = i;
                    count++;
                }
            }
        }
        
        return sessionIds;
    }

    /**
     * @dev Get only the players for a specific session
     * @param sessionId The ID of the session to query
     * @return players Array of player addresses in this session
     */
    function getSessionPlayers(uint256 sessionId) external view returns (address[] memory players) {
        require(sessionId > 0 && sessionId <= sessionCount, "WizverseSessions: invalid sessionId");
        return gameSessions[sessionId].players;
    }

    /**
     * @dev Internal pure function to compare two address arrays for equality.
     */
    function _areAddressesEqual(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) {
            return false;
        }
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Internal pure function to compare two uint256 arrays for equality.
     */
    function _areUintArraysEqual(uint256[] memory a, uint256[] memory b) internal pure returns (bool) {
        if (a.length != b.length) {
            return false;
        }
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Request to claim rewards for the sender
     * @notice This function checks all sessions for unclaimed rewards for the caller
     * @param sender The address of the wallet claiming rewards
     * @return success True if the request was successful
     */
    function requestToClaimRewards(address sender) external onlyCore returns (bool success) {
        // Create temporary arrays to track sessions with pending rewards
        // address[] memory walletsDistributed = new address[](1); // Unused variable
        // uint256[] memory amountsDistributed = new uint256[](1); // Unused variable
        
        // Initialize with empty values
        // walletsDistributed[0] = address(0); // Unused variable
        // amountsDistributed[0] = 0; // Unused variable
        
        uint256 totalAmount = 0;
        bool addedToWaitingList = false; // Flag to ensure we add only once
        
        // Iterate through all sessions to find ones where sender is a winner
        for (uint256 i = 1; i <= sessionCount; i++) {
            GameSession storage session = gameSessions[i];
            
            // Check if session has a winning outcome and hasn't been distributed yet
            if (uint8(session.outcome) > 0 && !session.winnerDistribution) {
                
                // Check if sender is in the winnersWallets array
                for (uint256 j = 0; j < session.winnersWallets.length; j++) {
                    if (session.winnersWallets[j] == sender) {
                        // Found sender as a winner in this session
                        uint256 rewardAmount = session.winnerAmounts[j];
                        totalAmount += rewardAmount;
                        
                        // Add to waiting list ONLY if not already added in this call
                        if (!addedToWaitingList) {
                            walletsWaitingForDistribution.push(sender);
                            amountsWaitingForDistribution.push(rewardAmount); // Push the amount for this specific session
                            tokensWaitingForDistribution.push(session.winnerToken);
                            sessionIdsWaitingForDistribution.push(i);
                            addedToWaitingList = true; // Mark as added
                        }
                        
                        // Emit event for tracking (can emit for each found reward)
                        emit RewardClaimRequested(i, sender, rewardAmount);
                        
                        // Since we found the sender in this session, no need to check other winners in the same session
                        break; // Exit inner loop (winnersWallets)
                    }
                }
            }
            // If we already added the user to the list in this call, we can stop checking other sessions
            // Note: This assumes we only add the user ONCE per call, even if they have multiple sessions ready.
            // If the user should be added for each session, remove this outer break.
            if (addedToWaitingList) {
                 break; // Exit outer loop (sessions)
            }
        }
        
        require(totalAmount > 0, "WizverseSessions: no rewards available for claiming");
        require(addedToWaitingList, "WizverseSessions: Failed to add to waiting list despite available rewards"); // Sanity check
        
        return true;
    }
    
    /**
     * @dev Event emitted when a wallet requests to claim rewards
     */
    event RewardClaimRequested(uint256 indexed sessionId, address indexed wallet, uint256 amount);

        /**
     * @dev Allows the owner to withdraw the entire native coin balance of the contract.
     * Sends the balance to the owner's address.
     */
    function withdrawEther() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "WizverseSessions: No native balance to withdraw");
        payable(owner()).sendValue(balance); // Send to owner
    }

    /**
     * @dev Allows the owner to withdraw the entire balance of a specific ERC20 token.
     * @param tokenContract The address of the ERC20 token contract.
     * @param recipient The address to receive the tokens.
     */
    function withdrawTokens(address tokenContract, address recipient) external onlyOwner {
        require(recipient != address(0), "WizverseSessions: recipient cannot be zero address");
        IERC20 token = IERC20(tokenContract);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "WizverseSessions: No token balance to withdraw");
        require(token.transfer(recipient, balance), "WizverseSessions: Token transfer failed");
    }

    /**
     * @dev Confirm a reward claim and send funds to the winner
     * @param winner The address of the winner to confirm rewards for
     * @return success True if the claim was confirmed successfully
     */
    function confirmClaim(address winner) external onlyOwner returns (bool success) {
        // --- CHECKS ---
        require(winner != address(0), "WizverseSessions: invalid winner address");
        
        // Find the first pending claim for this winner (assuming one claim per confirmation for now)
        uint256 claimIndex = type(uint256).max; // Initialize with invalid index
        for (uint256 i = 0; i < walletsWaitingForDistribution.length; i++) {
            if (walletsWaitingForDistribution[i] == winner) {
                claimIndex = i;
                break; // Found the first claim, stop searching
            }
        }
        
        require(claimIndex != type(uint256).max, "WizverseSessions: No pending claim for this winner");

        uint256 amount = amountsWaitingForDistribution[claimIndex];
        address token = tokensWaitingForDistribution[claimIndex];
        uint256 sessionId = sessionIdsWaitingForDistribution[claimIndex];

        require(amount > 0, "WizverseSessions: Claim amount must be positive");

        // --- EFFECTS ---
        
        // 1. Update the session with distribution info
        GameSession storage session = gameSessions[sessionId];
        session.winnersWalletsDistributed.push(winner);
        session.winnerDistributedAmounts.push(amount);
        
        // Check if all original winners have now been paid
        bool allWinnersPaid = true;
        if (session.winnersWallets.length == session.winnersWalletsDistributed.length) {
             // Basic length check first, then potentially a more robust check if needed
             // (For simplicity, assuming lengths matching means all paid for now)
             // TODO: If winners can be non-unique or order matters, add a more detailed check here.
             session.winnerDistribution = true;
        } else {
            allWinnersPaid = false; // If lengths don't match, not all paid yet
        }
        
        // 2. Remove the claim from the waiting lists using Swap and Pop
        uint256 len = walletsWaitingForDistribution.length;
        uint256 lastIndex = len - 1; 

        // If the item to remove is not the last item, swap it with the last item
        if (claimIndex < lastIndex) {
            walletsWaitingForDistribution[claimIndex] = walletsWaitingForDistribution[lastIndex];
            amountsWaitingForDistribution[claimIndex] = amountsWaitingForDistribution[lastIndex];
            tokensWaitingForDistribution[claimIndex] = tokensWaitingForDistribution[lastIndex];
            sessionIdsWaitingForDistribution[claimIndex] = sessionIdsWaitingForDistribution[lastIndex];
        }

        // Pop the last element
        walletsWaitingForDistribution.pop();
        amountsWaitingForDistribution.pop();
        tokensWaitingForDistribution.pop();
        sessionIdsWaitingForDistribution.pop();
        
        // 3. Emit event *before* interaction
        emit RewardClaimConfirmed(sessionId, winner, amount);

        // --- INTERACTIONS ---
        if (token == address(0)) {
            // Native currency
            require(address(this).balance >= amount, "WizverseSessions: insufficient contract balance for native payment");
            payable(winner).sendValue(amount); 
        } else {
            // ERC20 token
            IERC20 tokenContract = IERC20(token);
            require(tokenContract.balanceOf(address(this)) >= amount, "WizverseSessions: insufficient contract balance for token payment");
            require(tokenContract.transfer(winner, amount), "WizverseSessions: Token transfer failed on claim");
        }
        
        return true;
    }

    // OPTION 1: Get the whole array (potentially expensive for large arrays)
    function getWaitingWallets() external view returns (address[] memory) {
        return walletsWaitingForDistribution;
    }

    // OPTION 2: Get just the length
    function getWaitingWalletsLength() external view returns (uint256) {
        return walletsWaitingForDistribution.length;
    }

    /**
     * @dev Checks if a wallet has rewards waiting, the total amount, and associated platform IDs.
     * @param wallet The address of the wallet to check.
     * @return hasWaitingRewards True if rewards are waiting for the wallet.
     * @return waitingRewards An array of RewardAmount structs detailing pending rewards by token type.
     * @return platformIds An array of unique platform token IDs associated with the waiting rewards.
     * @notice This function iterates through the waiting lists, which could be gas-intensive if the lists are very large.
     */
    function getWaitingWallet(address wallet)
        external
        view
        returns (bool hasWaitingRewards, RewardAmount[] memory waitingRewards, uint256[] memory platformIds)
    {
        // Use a dynamic approach to handle multiple token types
        RewardAmount[] memory tempRewards = new RewardAmount[](walletsWaitingForDistribution.length); // Over-allocate
        address[] memory foundTokens = new address[](walletsWaitingForDistribution.length); // Over-allocate
        uint256 uniqueTokenCount = 0;
        
        uint256 foundPlatformCount = 0;
        uint256[] memory tempPlatformIds = new uint256[](walletsWaitingForDistribution.length);

        for (uint256 i = 0; i < walletsWaitingForDistribution.length; i++) {
            if (walletsWaitingForDistribution[i] == wallet) {
                if (!hasWaitingRewards) {
                    hasWaitingRewards = true;
                }

                address tokenAddress = tokensWaitingForDistribution[i];
                uint256 rewardAmount = amountsWaitingForDistribution[i];

                // Aggregate amounts by token type
                bool tokenExists = false;
                for (uint256 tIdx = 0; tIdx < uniqueTokenCount; tIdx++) {
                    if (foundTokens[tIdx] == tokenAddress) {
                        tempRewards[tIdx].amount += rewardAmount;
                        tokenExists = true;
                        break;
                    }
                }
                if (!tokenExists) {
                    foundTokens[uniqueTokenCount] = tokenAddress;
                    tempRewards[uniqueTokenCount] = RewardAmount(tokenAddress, rewardAmount);
                    uniqueTokenCount++;
                }

                uint256 sessionId = sessionIdsWaitingForDistribution[i];
                if (sessionId > 0 && sessionId <= sessionCount) {
                     uint256 platformId = gameSessions[sessionId].platformTokenId;
                     
                     bool alreadySeen = false;
                     for (uint256 j = 0; j < foundPlatformCount; j++) {
                         // slither-disable-next-line incorrect-equality
                         if (tempPlatformIds[j] == platformId) {
                             alreadySeen = true;
                             break;
                         }
                     }
                     if (!alreadySeen) {
                        tempPlatformIds[foundPlatformCount] = platformId;
                        foundPlatformCount++;
                     }
                }
            }
        }

        // Resize rewards array
        waitingRewards = new RewardAmount[](uniqueTokenCount);
        for(uint k=0; k < uniqueTokenCount; k++){
            waitingRewards[k] = tempRewards[k];
        }

        // Resize platforms array
        platformIds = new uint256[](foundPlatformCount);
        for (uint256 i = 0; i < foundPlatformCount; i++) {
            platformIds[i] = tempPlatformIds[i];
        }
    }

    /**
     * @dev Checks if a sender is eligible to successfully call requestToClaimRewards.
     * Iterates through sessions to find if the sender is a winner in any session
     * where rewards haven't been fully distributed yet. Also returns aggregated pending reward amounts.
     * @param sender The address of the wallet to check eligibility for.
     * @return canActuallyRequest True if the sender has at least one unclaimed reward.
     * @return pendingRewards An array of RewardAmount structs detailing pending rewards by token type.
     */
    function canRequestRewards(address sender) external view returns (bool canActuallyRequest, RewardAmount[] memory pendingRewards) {
        canActuallyRequest = false;
        // Max 10 different token types + 1 native as an estimate. Adjust if more are expected.
        RewardAmount[] memory tempRewards = new RewardAmount[](11);
        address[] memory foundTokens = new address[](11);
        uint256 uniqueTokenCount = 0;

        for (uint256 i = 1; i <= sessionCount; i++) {
            GameSession storage session = gameSessions[i];
            
            if (uint8(session.outcome) > 0 && !session.winnerDistribution) {
                for (uint256 j = 0; j < session.winnersWallets.length; j++) {
                    if (session.winnersWallets[j] == sender) {
                        canActuallyRequest = true;
                        uint256 rewardAmount = session.winnerAmounts[j];
                        address tokenAddress = session.winnerToken; // This should be set in updateSession

                        if (rewardAmount > 0) {
                            bool tokenExists = false;
                            for (uint256 tIdx = 0; tIdx < uniqueTokenCount; tIdx++) {
                                if (foundTokens[tIdx] == tokenAddress) {
                                    tempRewards[tIdx].amount += rewardAmount;
                                    tokenExists = true;
                                    break;
                                }
                            }
                            if (!tokenExists && uniqueTokenCount < tempRewards.length) {
                                foundTokens[uniqueTokenCount] = tokenAddress;
                                tempRewards[uniqueTokenCount] = RewardAmount(tokenAddress, rewardAmount);
                                uniqueTokenCount++;
                            }
                            // If uniqueTokenCount >= tempRewards.length, we have an issue (too many token types)
                            // For a robust solution, dynamic arrays or a two-pass approach might be needed
                            // if the number of token types can exceed a small fixed limit.
                            // For now, this handles up to 11 types.
                        }
                        // Assuming one win per session for a user for simplicity here.
                        // If a user can win multiple times (different tokens/amounts) in *one* session, 
                        // this logic might need to sum them up before checking foundTokens.
                        // However, session.winnerAmounts[j] should be the total for that winner in that session.
                        break; // Found sender in this session's winners, move to next session
                    }
                }
            }
        }

        pendingRewards = new RewardAmount[](uniqueTokenCount);
        for (uint256 k = 0; k < uniqueTokenCount; k++) {
            pendingRewards[k] = tempRewards[k];
        }
    }

    // ---------------------------------------------------------------------
    // Helper for Core to fetch winners wallets & amounts in a single call
    // ---------------------------------------------------------------------
    function getWinnerDetails(uint256 sessionId) external view returns (address[] memory wallets, uint256[] memory amounts) {
        require(sessionId > 0 && sessionId <= sessionCount, "WizverseSessions: invalid sessionId");
        GameSession storage session = gameSessions[sessionId];
        wallets = session.winnersWallets;
        amounts = session.winnerAmounts;
    }

    // --- New Getter for Core to Fetch Session Details for Event Emission ---
    function getFullSessionDetails(uint256 sessionId) 
        external 
        view 
        returns (
            SessionType sessionType,
            uint256 platformTokenId,
            address[] memory players,
            uint256[][] memory teamCharacterTokenIds,
            uint256[][] memory teamWeaponTokenIds,
            uint256 timestamp
    ) {
        require(sessionId > 0 && sessionId <= sessionCount, "WizverseSessions: invalid sessionId");
        GameSession storage session = gameSessions[sessionId];
        
        return (
            session.sessionType,
            session.platformTokenId,
            session.players,
            session.teamCharacterTokenIds,
            session.teamWeaponTokenIds,
            session.timestamp
        );
    }
}