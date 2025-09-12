// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title IVersioned
 * @dev Interface for contracts that track versions for upgrade validation
 */
interface IVersioned {
    /// @dev Returns the version of the implementation
    function getVersion() external pure returns (uint256);
}

/**
 * @title MandalaPresale
 * @dev Smart contract for conducting presale of Mandala tokens with multiple payment options
 *
 * Key Features:
 * - Multi-token payment support (ETH, USDT, USDC)
 * - USD-based pricing via Chainlink oracles
 * - Referral system with reward allocation
 * - Hard cap and soft cap enforcement
 * - Upgradeable using UUPS proxy pattern
 * - Comprehensive security measures
 * - Token distribution after TGE (no claiming during presale)
 *
 * @notice This contract facilitates the presale of $KPANG tokens with ETH and stablecoin payments
 * @author Senior Blockchain Developer
 */
contract MandalaPresale is
Initializable,
UUPSUpgradeable,
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
PausableUpgradeable
{
    using SafeERC20 for IERC20;
    // ============ CONSTRUCTOR ============
    
    /// @dev Constructor that disables initializers to prevent implementation contract initialization
    /// @notice This protects the implementation contract from being initialized by unauthorized parties
    constructor() {
        _disableInitializers();
    }

    // ============ STATE VARIABLES ============

    /// @dev The ERC20 token being sold in the presale
    IERC20 public mandalaToken;

    /// @dev Token price in USD with 18 decimals (e.g., 0.1 USD = 100000000000000000)
    uint256 public tokenPriceUSD;

    /// @dev Presale start time (Unix timestamp)
    uint256 public startTime;

    /// @dev Presale end time (Unix timestamp)
    uint256 public endTime;

    /// @dev Maximum amount to raise in USD (with 18 decimals)
    uint256 public hardCapUSD;

    /// @dev Total amount raised so far in USD (with 18 decimals)
    uint256 public totalRaisedUSD;

    /// @dev Mapping of stablecoin addresses to their acceptance status
    /// @notice True means the stablecoin is accepted for payments
    mapping(address => bool) public acceptedStablecoins;

    /// @dev Chainlink price feed for ETH/USD
    AggregatorV3Interface public ETHPriceFeed;

    /// @dev Chainlink price feed for USDT/USD
    AggregatorV3Interface public USDTPriceFeed;

    /// @dev Percentage of purchase amount awarded to referrer (with 2 decimals: 500 = 5%)
    uint256 public referralRewardPercent;

    /// @dev Mapping to track who referred whom (buyer => referrer)
    mapping(address => address) public referrerOf;

    /// @dev Mapping to track referral rewards owed to each referrer
    mapping(address => uint256) public referralRewards;
    
    /// @dev Mapping to track USDT referral rewards owed to each referrer
    mapping(address => uint256) public referralRewardsUSDT;
    
    /// @dev Mapping to track TOKEN referral rewards owed to each referrer
    mapping(address => uint256) public referralRewardsTOKEN;

    /// @dev Total referral rewards allocated (for reserve tracking)
    uint256 public totalReferralRewardsAllocated;
    
    /// @dev Total USDT referral rewards allocated
    uint256 public totalReferralRewardsAllocatedUSDT;
    
    /// @dev Total TOKEN referral rewards allocated  
    uint256 public totalReferralRewardsAllocatedTOKEN;

    /// @dev Mapping to track total tokens purchased by each address
    mapping(address => uint256) public tokensPurchased;

    /// @dev Mapping to track total USD contribution by each address
    mapping(address => uint256) public contributionsUSD;


    /// @dev Mapping to track claimable tokens for each user
    mapping(address => uint256) public claimableTokens;

    /// @dev Fund routing wallets
    address public walletA;
    address public walletB;
    address public treasuryWallet;

    /// @dev Current presale round
    uint256 public currentRound;

    /// @dev Reward type enum for referral payouts
    enum RewardType { USDT, TOKEN }

    /// @dev Mapping of round to reward type
    mapping(uint256 => RewardType) public referralRewardType;

    /// @dev Vesting schedule for token claims
    struct VestingSchedule {
        uint256 cliff;          // Cliff period in seconds
        uint256 duration;       // Total vesting duration in seconds
        uint256 startTime;      // Vesting start time
        bool revocable;         // Whether vesting can be revoked
    }

    /// @dev Global vesting schedule
    VestingSchedule public vestingSchedule;

    /// @dev Track vested amounts for each user
    mapping(address => uint256) public vestedTokens;

    /// @dev Track if user has started vesting
    mapping(address => bool) public vestingStarted;

    /// @dev Maximum allowed staleness for price feeds (configurable)
    uint256 public priceFeedStalenessThreshold;
    
    /// @dev Fund distribution percentages (basis points: 1000 = 10%)
    uint256 public walletAPercent;   // 10% (initialized in initialize())
    uint256 public walletBPercent;    // 2% (initialized in initialize())
    uint256 public treasuryPercent;  // 88% (initialized in initialize())

    /// @dev Array to track all accepted stablecoins for iteration
    address[] public acceptedStablecoinsList;
    
    /// @dev Primary stablecoin for referral payouts (typically USDT)
    address public primaryStablecoin;
    
    /// @dev Total tokens allocated to all users across all purchases
    uint256 public totalClaimableTokens;
    
    /// @dev Mapping of authorized implementation addresses for upgrades
    mapping(address => bool) public authorizedImplementations;
    
    /// @dev Flag to enable/disable implementation whitelist (default: enabled for security)
    bool public implementationWhitelistEnabled;
    
    /// @dev Current contract version for upgrade tracking
    uint256 public contractVersion;

    // ============ EVENTS ============

    /// @dev Emitted when tokens are purchased
    event TokensPurchased(
        address indexed buyer,
        uint256 usdAmount,
        uint256 tokens,
        address paymentToken,
        uint256 paymentAmount
    );

    /// @dev Emitted when referral reward is recorded
    event ReferralRewardRecorded(
        address indexed referrer,
        address indexed buyer,
        uint256 rewardAmount
    );

    // TokensClaimed event removed - tokens distributed after TGE

    /// @dev Emitted when referral rewards are claimed
    event ReferralRewardClaimed(
        address indexed referrer,
        uint256 amount
    );

    /// @dev Emitted when funds are distributed
    event FundsDistributed(
        uint256 toWalletA,
        uint256 toWalletB,
        uint256 toTreasury
    );

    /// @dev Emitted when round changes
    event RoundChanged(
        uint256 newRound,
        RewardType rewardType
    );

    /// @dev Emitted when vesting schedule is configured
    event VestingConfigured(
        uint256 cliff,
        uint256 duration,
        uint256 startTime
    );

    /// @dev Emitted when token price is updated
    event TokenPriceUpdated(
        uint256 oldPrice,
        uint256 newPrice
    );

    /// @dev Emitted when referral reward percentage is updated
    event ReferralRewardPercentUpdated(
        uint256 oldPercent,
        uint256 newPercent
    );

    /// @dev Emitted when accepted stablecoin status is updated
    event AcceptedStablecoinUpdated(
        address indexed stablecoin,
        bool accepted
    );

    /// @dev Emitted when primary stablecoin is updated
    event PrimaryStablecoinUpdated(
        address indexed oldStablecoin,
        address indexed newStablecoin
    );

    /// @dev Emitted when price feeds are updated
    event PriceFeedsUpdated(
        address indexed ethPriceFeed,
        address indexed usdtPriceFeed
    );

    /// @dev Emitted when presale timing is updated
    event PresaleTimingUpdated(
        uint256 oldStartTime,
        uint256 oldEndTime,
        uint256 newStartTime,
        uint256 newEndTime
    );

    /// @dev Emitted when fund wallets are updated
    event FundWalletsUpdated(
        address indexed walletA,
        address indexed walletB,
        address indexed treasuryWallet
    );

    /// @dev Emitted when fund distribution percentages are updated
    event FundDistributionPercentagesUpdated(
        uint256 walletAPercent,
        uint256 walletBPercent,
        uint256 treasuryPercent
    );

    /// @dev Emitted when authorized implementation status is updated
    event AuthorizedImplementationUpdated(
        address indexed implementation,
        bool authorized
    );

    /// @dev Emitted when implementation whitelist is enabled/disabled
    event ImplementationWhitelistToggled(
        bool enabled
    );

    /// @dev Emitted when price feed staleness threshold is updated
    event PriceFeedStalenessThresholdUpdated(
        uint256 oldThreshold,
        uint256 newThreshold
    );

    /// @dev Emitted when contract is paused
    event ContractPaused(
        address indexed account
    );

    /// @dev Emitted when contract is unpaused
    event ContractUnpaused(
        address indexed account
    );

    /// @dev Emitted when tokens are recovered in emergency
    event TokensRecovered(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ============ MODIFIERS ============

    /// @dev Ensures presale is currently active
    modifier onlyDuringPresale() {
        require(block.timestamp >= startTime, "Presale not started");
        require(block.timestamp < endTime + 1, "Presale ended");
        _;
    }

    /// @dev Ensures hard cap is not exceeded
    modifier withinHardCap(uint256 usdAmount) {
        require(
            totalRaisedUSD + usdAmount < hardCapUSD + 1,
            "Hard cap exceeded"
        );
        _;
    }

    // ============ INITIALIZATION ============

    /// @dev Initializes the contract (replaces constructor in upgradeable contracts)
    /// @param _mandalaToken Address of the token being sold
    /// @param _tokenPriceUSD Price per token in USD (18 decimals)
    /// @param _startTime Presale start timestamp
    /// @param _endTime Presale end timestamp
    /// @param _hardCapUSD Maximum USD to raise (18 decimals)
    /// @param _ETHPriceFeed Address of ETH/USD Chainlink price feed
    /// @param _USDTPriceFeed Address of USDT/USD Chainlink price feed
    /// @param _referralRewardPercent Referral reward percentage (2 decimals)
    /// @param _walletA Address for 10% fund allocation
    /// @param _walletB Address for 2% fund allocation 
    /// @param _treasuryWallet Address for 88% fund allocation
    function initialize(
        address _mandalaToken,
        uint256 _tokenPriceUSD,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _hardCapUSD,
        address _ETHPriceFeed,
        address _USDTPriceFeed,
        uint256 _referralRewardPercent,
        address _walletA,
        address _walletB,
        address _treasuryWallet
    ) public initializer {
        // Initialize parent contracts
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Validate critical parameters
        _validateInitParams(_mandalaToken, _tokenPriceUSD, _startTime, _endTime, _hardCapUSD, _ETHPriceFeed, _USDTPriceFeed, _referralRewardPercent);

        // Set initial values
        mandalaToken = IERC20(_mandalaToken);
        tokenPriceUSD = _tokenPriceUSD;
        startTime = _startTime;
        endTime = _endTime;
        hardCapUSD = _hardCapUSD;
        ETHPriceFeed = AggregatorV3Interface(_ETHPriceFeed);
        USDTPriceFeed = AggregatorV3Interface(_USDTPriceFeed);
        referralRewardPercent = _referralRewardPercent;

        // Set fund routing wallets
        require(_walletA != address(0), "Invalid wallet A");
        require(_walletB != address(0), "Invalid wallet B");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        walletA = _walletA;
        walletB = _walletB;
        treasuryWallet = _treasuryWallet;

        // Initialize round and referral reward types
        currentRound = 1;
        referralRewardType[1] = RewardType.USDT;
        referralRewardType[2] = RewardType.USDT;
        // Round 3+ defaults to TOKEN (RewardType.TOKEN = 1)

        // Initialize fund distribution percentages
        walletAPercent = 1000;   // 10%
        walletBPercent = 200;    // 2%
        treasuryPercent = 8800;  // 88%

        
        // Enable implementation whitelist by default for security
        implementationWhitelistEnabled = true;
        
        // Set default price feed staleness threshold to 24 hours
        priceFeedStalenessThreshold = 24 hours;
        
        // Initialize contract version for upgrade tracking
        contractVersion = 1;
    }

    // ============ CORE PURCHASE FUNCTIONS ============

    /// @dev Allows users to buy tokens with ETH
    /// @param _referrer Address of the referrer (optional, can be address(0))
    function buyWithETH(address _referrer)
    external
    payable
    nonReentrant
    whenNotPaused
    onlyDuringPresale
    {
        require(msg.value != 0, "ETH amount must be > 0");

        // Get current ETH price in USD from Chainlink
        uint256 ethPriceUSD = getETHPriceUSD();

        // Calculate USD equivalent of ETH sent
        uint256 usdAmount = (msg.value * ethPriceUSD) / 1e18;

        // Ensure hard cap not exceeded
        require(
            totalRaisedUSD + usdAmount < hardCapUSD + 1,
            "Hard cap would be exceeded"
        );

        // Process the purchase
        _processPurchase(msg.sender, usdAmount, _referrer, address(0), msg.value);

        // Distribute ETH funds immediately
        _distributeFunds(msg.value, true);
    }

    /// @dev Allows users to buy tokens with stablecoins (USDT, USDC, etc.)
    /// @param stablecoin Address of the stablecoin contract
    /// @param amount Amount of stablecoin to spend
    /// @param _referrer Address of the referrer (optional, can be address(0))
    function buyWithStablecoin(
        address stablecoin,
        uint256 amount,
        address _referrer
    )
    external
    nonReentrant
    whenNotPaused
    onlyDuringPresale
    {
        require(stablecoin != address(0), "Invalid stablecoin address");
        require(acceptedStablecoins[stablecoin], "Stablecoin not accepted");
        require(amount != 0, "Amount must be > 0");

        // Get stablecoin decimals and convert to USD (18 decimals)
        IERC20 stablecoinContract = IERC20(stablecoin);
        uint8 decimals;
        
        // Safely get decimals from the token contract
        try IERC20Metadata(stablecoin).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            // Revert if token doesn't support ERC20Metadata decimals() function
            revert("Token needs decimals()");
        }
        
        // Convert to 18 decimals for internal USD calculations
        uint256 usdAmount;
        if (decimals <= 17) {
            usdAmount = amount * (10 ** (18 - decimals));
        } else if (decimals >= 19) {
            usdAmount = amount / (10 ** (decimals - 18));
        } else {
            usdAmount = amount; // Already 18 decimals
        }

        // Ensure hard cap not exceeded (check with intended amount first)
        require(
            totalRaisedUSD + usdAmount < hardCapUSD + 1,
            "Hard cap would be exceeded"
        );

        // Check balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = stablecoinContract.balanceOf(address(this));

        // Transfer stablecoins from user to contract (using safe transfer for USDT compatibility)
        stablecoinContract.safeTransferFrom(msg.sender, address(this), amount);

        // Check balance after transfer to get actual received amount
        uint256 balanceAfter = stablecoinContract.balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        
        // Ensure we actually received tokens
        require(actualAmount != 0, "No tokens received");

        // Recalculate USD amount based on actual received tokens
        uint256 actualUsdAmount;
        if (decimals <= 17) {
            actualUsdAmount = actualAmount * (10 ** (18 - decimals));
        } else if (decimals >= 19) {
            actualUsdAmount = actualAmount / (10 ** (decimals - 18));
        } else {
            actualUsdAmount = actualAmount; // Already 18 decimals
        }

        // Final hard cap check with actual amount
        require(
            totalRaisedUSD + actualUsdAmount < hardCapUSD + 1,
            "Hard cap would be exceeded with actual amount"
        );

        // Process the purchase with actual received amount
        _processPurchase(msg.sender, actualUsdAmount, _referrer, stablecoin, actualAmount);

        // Note: Stablecoin distribution handled in admin withdrawal
    }

    // ============ INTERNAL FUNCTIONS ============

    /// @dev Validates initialization parameters to prevent stack too deep error
    /// @param _mandalaToken Address of the token being sold
    /// @param _tokenPriceUSD Price per token in USD (18 decimals)
    /// @param _startTime Presale start timestamp
    /// @param _endTime Presale end timestamp
    /// @param _hardCapUSD Maximum USD to raise (18 decimals)
    /// @param _ETHPriceFeed Address of ETH/USD Chainlink price feed
    /// @param _USDTPriceFeed Address of USDT/USD Chainlink price feed
    /// @param _referralRewardPercent Referral reward percentage (2 decimals)
    function _validateInitParams(
        address _mandalaToken,
        uint256 _tokenPriceUSD,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _hardCapUSD,
        address _ETHPriceFeed,
        address _USDTPriceFeed,
        uint256 _referralRewardPercent
    ) internal view {
        require(_mandalaToken != address(0), "Invalid token address");
        require(_tokenPriceUSD != 0, "Token price must be > 0");
        require(_startTime > block.timestamp, "Start time must be future");
        require(_startTime < _endTime, "Start must be before end");
        require(_endTime > block.timestamp, "End time must be future");
        require(_hardCapUSD != 0, "Hard cap must be > 0");
        require(_ETHPriceFeed != address(0), "Invalid ETH price feed");
        require(_USDTPriceFeed != address(0), "Invalid USDT price feed");
        require(_referralRewardPercent < 10001, "Referral reward > 100%");
    }


    /// @dev Internal function to process token purchases and referrals
    /// @param buyer Address of the token buyer
    /// @param usdAmount USD amount of the purchase (18 decimals)
    /// @param _referrer Address of the referrer
    /// @param paymentToken Address of payment token (address(0) for ETH)
    /// @param paymentAmount Amount of payment token used
    function _processPurchase(
        address buyer,
        uint256 usdAmount,
        address _referrer,
        address paymentToken,
        uint256 paymentAmount
    ) internal withinHardCap(usdAmount) {
        // Calculate number of tokens to give with overflow protection
        uint256 tokensToGive;
        if (usdAmount > type(uint256).max / 1e18) {
            // If multiplication would overflow, calculate differently
            tokensToGive = (usdAmount / tokenPriceUSD) * 1e18;
        } else {
            // Safe to multiply first
            tokensToGive = (usdAmount * 1e18) / tokenPriceUSD;
        }

        // Update purchase tracking
        tokensPurchased[buyer] += tokensToGive;
        contributionsUSD[buyer] += usdAmount;
        totalRaisedUSD += usdAmount;

        // Add tokens to user's claimable amount
        claimableTokens[buyer] += tokensToGive;
        
        // Track total claimable tokens across all users
        totalClaimableTokens += tokensToGive;

        // Handle referral if provided and valid
        if (_referrer != address(0) && _referrer != buyer) {
            _recordReferral(buyer, _referrer, usdAmount);
        }

        // Emit purchase event
        emit TokensPurchased(buyer, usdAmount, tokensToGive, paymentToken, paymentAmount);
    }

    /// @dev Records referral relationship and calculates rewards
    /// @param buyer Address of the buyer
    /// @param _referrer Address of the referrer
    /// @param usdAmount USD amount of the purchase
    function _recordReferral(
        address buyer,
        address _referrer,
        uint256 usdAmount
    ) internal {
        // Prevent self-referrals (security measure)
        require(_referrer != buyer, "Cannot refer yourself");

        // Record the referral relationship (only first time)
        if (referrerOf[buyer] == address(0)) {
            referrerOf[buyer] = _referrer;
        }

        // Calculate and record referral reward in USD
        uint256 referralReward = (usdAmount * referralRewardPercent) / 10000;
        
        // Determine reward type based on current round
        RewardType rewardType = _getReferralRewardType(currentRound);
        
        // Track rewards by type for accurate distribution
        if (rewardType == RewardType.USDT) {
            referralRewardsUSDT[_referrer] += referralReward;
            totalReferralRewardsAllocatedUSDT += referralReward;
        } else {
            referralRewardsTOKEN[_referrer] += referralReward;
            totalReferralRewardsAllocatedTOKEN += referralReward;
        }
        
        // Keep legacy tracking for backward compatibility
        referralRewards[_referrer] += referralReward;
        totalReferralRewardsAllocated += referralReward;

        emit ReferralRewardRecorded(_referrer, buyer, referralReward);
    }

    /// @dev Distributes funds according to allocation percentages
    /// @param amount Amount to distribute
    /// @param isETH Whether the funds are ETH (true) or handled separately (false)
    function _distributeFunds(uint256 amount, bool isETH) internal {
        uint256 toWalletA = (amount * walletAPercent) / 10000;
        uint256 toWalletB = (amount * walletBPercent) / 10000;
        uint256 toTreasury = (amount * treasuryPercent) / 10000;

        if (isETH) {
            // Distribute ETH
            (bool successA, ) = payable(walletA).call{value: toWalletA}("");
            require(successA, "Transfer to wallet A failed");
            
            (bool successB, ) = payable(walletB).call{value: toWalletB}("");
            require(successB, "Transfer to wallet B failed");
            
            (bool successTreasury, ) = payable(treasuryWallet).call{value: toTreasury}("");
            require(successTreasury, "Transfer to treasury failed");
        }

        emit FundsDistributed(toWalletA, toWalletB, toTreasury);
    }

    // ============ CLAIM FUNCTIONS ============
    
    // Note: Token claiming removed - tokens will be distributed after TGE
    // The claimableTokens mapping still tracks allocations for each user

    /// @dev Allows referrers to claim their USDT referral rewards
    function claimReferralRewardsUSDT() external nonReentrant {
        require(referralRewardsUSDT[msg.sender] != 0, "No USDT rewards to claim");

        uint256 usdRewards = referralRewardsUSDT[msg.sender];
        referralRewardsUSDT[msg.sender] = 0;
        
        // Also update legacy tracking
        if (referralRewards[msg.sender] >= usdRewards) {
            referralRewards[msg.sender] -= usdRewards;
        }

        // Pay in USDT with proper decimal handling
        address usdtAddress = _getAcceptedStablecoin();
        require(usdtAddress != address(0), "USDT not configured");
        
        IERC20 usdt = IERC20(usdtAddress);
        
        // Get USDT decimals dynamically for accurate conversion
        uint8 usdtDecimals;
        try IERC20Metadata(usdtAddress).decimals() returns (uint8 d) {
            usdtDecimals = d;
        } catch {
            // Revert if USDT token doesn't support ERC20Metadata decimals() function
            revert("USDT needs decimals()");
        }
        
        // Convert from 18 decimals (internal USD) to USDT decimals
        uint256 usdtAmount;
        if (usdtDecimals <= 17) {
            usdtAmount = usdRewards / (10 ** (18 - usdtDecimals));
        } else if (usdtDecimals >= 19) {
            usdtAmount = usdRewards * (10 ** (usdtDecimals - 18));
        } else {
            usdtAmount = usdRewards; // Already 18 decimals
        }
        
        usdt.safeTransfer(msg.sender, usdtAmount);
        
        emit ReferralRewardClaimed(msg.sender, usdtAmount);
    }

    /// @dev Allows referrers to claim their TOKEN referral rewards
    function claimReferralRewardsToken() external nonReentrant {
        require(referralRewardsTOKEN[msg.sender] != 0, "No TOKEN rewards to claim");

        uint256 usdRewards = referralRewardsTOKEN[msg.sender];
        referralRewardsTOKEN[msg.sender] = 0;
        
        // Also update legacy tracking
        if (referralRewards[msg.sender] >= usdRewards) {
            referralRewards[msg.sender] -= usdRewards;
        }

        // Pay in tokens with overflow protection
        uint256 tokensToTransfer;
        if (usdRewards > type(uint256).max / 1e18) {
            // If multiplication would overflow, calculate differently
            tokensToTransfer = (usdRewards / tokenPriceUSD) * 1e18;
        } else {
            // Safe to multiply first
            tokensToTransfer = (usdRewards * 1e18) / tokenPriceUSD;
        }
        
        mandalaToken.safeTransfer(msg.sender, tokensToTransfer);
        
        emit ReferralRewardClaimed(msg.sender, tokensToTransfer);
    }

    /// @dev Legacy function for claiming referral rewards (claims both USDT and TOKEN rewards)
    /// @notice This function is kept for backward compatibility but should be deprecated in favor of specific claim functions
    function claimReferralRewards() external nonReentrant {
        uint256 usdtRewards = referralRewardsUSDT[msg.sender];
        uint256 tokenRewards = referralRewardsTOKEN[msg.sender];
        
        require(usdtRewards != 0 || tokenRewards != 0, "No rewards to claim");

        // Claim USDT rewards if any
        if (usdtRewards != 0) {
            referralRewardsUSDT[msg.sender] = 0;
            
            // Pay in USDT
            address usdtAddress = _getAcceptedStablecoin();
            require(usdtAddress != address(0), "USDT not configured");
            
            IERC20 usdt = IERC20(usdtAddress);
            
            // Get USDT decimals dynamically for accurate conversion
            uint8 usdtDecimals;
            try IERC20Metadata(usdtAddress).decimals() returns (uint8 d) {
                usdtDecimals = d;
            } catch {
                // Revert if USDT token doesn't support ERC20Metadata decimals() function
                revert("USDT needs decimals()");
            }
            
            // Convert from 18 decimals (internal USD) to USDT decimals
            uint256 usdtAmount;
            if (usdtDecimals <= 17) {
                usdtAmount = usdtRewards / (10 ** (18 - usdtDecimals));
            } else if (usdtDecimals >= 19) {
                usdtAmount = usdtRewards * (10 ** (usdtDecimals - 18));
            } else {
                usdtAmount = usdtRewards;
            }
            
            usdt.safeTransfer(msg.sender, usdtAmount);
            
            emit ReferralRewardClaimed(msg.sender, usdtAmount);
        }

        // Claim TOKEN rewards if any
        if (tokenRewards != 0) {
            referralRewardsTOKEN[msg.sender] = 0;
            
            // Pay in tokens
            uint256 tokensToTransfer;
            if (tokenRewards > type(uint256).max / 1e18) {
                tokensToTransfer = (tokenRewards / tokenPriceUSD) * 1e18;
            } else {
                tokensToTransfer = (tokenRewards * 1e18) / tokenPriceUSD;
            }
            
            mandalaToken.safeTransfer(msg.sender, tokensToTransfer);
            
            emit ReferralRewardClaimed(msg.sender, tokensToTransfer);
        }
        
        // Update legacy tracking
        referralRewards[msg.sender] = 0;
    }

    // ============ PRICE FEED FUNCTIONS ============

    /// @dev Gets the latest ETH price in USD from Chainlink with comprehensive validation
    /// @return price ETH price in USD (18 decimals)
    function getETHPriceUSD() public view returns (uint256) {
        (uint80 roundID, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = ETHPriceFeed.latestRoundData();
        
        // Validate price data
        require(price > 0, "Chainlink ETH price <= 0");
        require(answeredInRound >= roundID, "Stale ETH price");
        require(updatedAt != 0, "ETH round not complete");
        require(block.timestamp - updatedAt < priceFeedStalenessThreshold + 1, "ETH price data is stale");

        // Chainlink price feeds have 8 decimals, convert to 18
        return uint256(price) * 1e10;
    }


    // ============ VIEW FUNCTIONS ============

    /// @dev Returns referral rewards for a specific referrer
    /// @param _referrer Address to check rewards for
    /// @return reward USD amount of rewards (18 decimals)
    function getReferralReward(address _referrer) external view returns (uint256) {
        return referralRewards[_referrer];
    }

    /// @dev Checks if presale is currently active
    /// @return active True if presale is active
    function isPresaleActive() external view returns (bool) {
        return block.timestamp >= startTime && block.timestamp <= endTime;
    }

    /// @dev Returns remaining time in presale
    /// @return timeLeft Seconds remaining (0 if presale ended)
    function getPresaleTimeLeft() external view returns (uint256) {
        if (block.timestamp >= endTime) {
            return 0;
        }
        return endTime - block.timestamp;
    }

    /// @dev Calculates vested token amount for a user with overflow protection
    /// @param user Address to calculate vested amount for
    /// @return amount Vested token amount available for claiming
    function _calculateVestedAmount(address user) internal view returns (uint256) {
        uint256 totalClaimable = claimableTokens[user];
        if (totalClaimable == 0) return 0;
        
        // If no vesting schedule, return all tokens
        if (vestingSchedule.startTime == 0 || vestingSchedule.duration == 0) {
            return totalClaimable - vestedTokens[user];
        }
        
        uint256 currentTime = block.timestamp;
        uint256 vestingStart = vestingSchedule.startTime;
        uint256 cliff = vestingSchedule.cliff;
        uint256 duration = vestingSchedule.duration;
        
        // Before cliff, no tokens are vested
        if (currentTime < vestingStart + cliff) {
            return 0;
        }
        
        // After full vesting period, all tokens are vested
        if (currentTime >= vestingStart + duration) {
            return totalClaimable - vestedTokens[user];
        }
        
        // Linear vesting between cliff and end with overflow protection
        uint256 timeElapsed = currentTime - vestingStart;
        uint256 vestedAmount;
        
        // Use safe arithmetic to prevent overflow
        if (totalClaimable > type(uint256).max / timeElapsed) {
            // If multiplication would overflow, calculate differently
            vestedAmount = (totalClaimable / duration) * timeElapsed;
        } else {
            // Safe to multiply first
            vestedAmount = (totalClaimable * timeElapsed) / duration;
        }
        
        // Return only newly vested tokens
        return vestedAmount > vestedTokens[user] ? vestedAmount - vestedTokens[user] : 0;
    }
    
    /// @dev Returns the referral reward type for a given round
    /// @param round Round number to check
    /// @return rewardType USDT or TOKEN
    function _getReferralRewardType(uint256 round) internal view returns (RewardType) {
        // For rounds 1-2, the mapping is explicitly set in initialize()
        // For rounds 3+, we check if the mapping was explicitly set via setReferralRewardType()
        // Since the mapping defaults to 0 (USDT), we can distinguish custom values:
        // - If round <= 2: always use mapping (set in initialize)
        // - If round > 2 and mapping == USDT: custom override to USDT
        // - If round > 2 and mapping == TOKEN: could be default (not set) or custom
        
        if (round <= 2) {
            // Rounds 1-2 are explicitly set in initialize(), always use mapping
            return referralRewardType[round];
        } else {
            // For rounds 3+, default is TOKEN
            // If mapping is USDT, it means owner explicitly set it to USDT (custom)
            // If mapping is TOKEN, use it (whether default or explicitly set doesn't matter)
            return referralRewardType[round] == RewardType.USDT ? RewardType.USDT : RewardType.TOKEN;
        }
    }
    
    /// @dev Returns the primary stablecoin for referral payouts
    /// @return stablecoin Address of primary stablecoin
    function _getAcceptedStablecoin() internal view returns (address) {
        return primaryStablecoin;
    }

    /// @dev Calculates total tokens needed for all claims including referral rewards
    /// @return totalNeeded Total tokens that must be available in contract
    function _calculateTotalTokensNeeded() internal view returns (uint256) {
        // Convert referral rewards from USD to tokens
        uint256 referralTokens = (totalReferralRewardsAllocated * 1e18) / tokenPriceUSD;
        
        // Add total claimable tokens across all users
        uint256 totalNeeded = totalClaimableTokens + referralTokens;
        
        return totalNeeded;
    }

    // ============ ADMIN FUNCTIONS ============

    /// @dev Sets the token price (only owner)
    /// @param _tokenPriceUSD New price in USD (18 decimals)
    function setTokenPrice(uint256 _tokenPriceUSD) external onlyOwner {
        require(_tokenPriceUSD != 0, "Price must be > 0");
        uint256 oldPrice = tokenPriceUSD;
        tokenPriceUSD = _tokenPriceUSD;
        emit TokenPriceUpdated(oldPrice, _tokenPriceUSD);
    }

    /// @dev Updates referral reward percentage (only owner)
    /// @param _referralRewardPercent New referral reward percentage in basis points (e.g., 500 = 5%)
    function setReferralRewardPercent(uint256 _referralRewardPercent) external onlyOwner {
        require(_referralRewardPercent < 10001, "Referral reward > 100%");
        uint256 oldPercent = referralRewardPercent;
        referralRewardPercent = _referralRewardPercent;
        emit ReferralRewardPercentUpdated(oldPercent, _referralRewardPercent);
    }

    /// @dev Adds or removes accepted stablecoins (only owner)
    /// @param stablecoin Address of the stablecoin
    /// @param accepted True to accept, false to reject
    function setAcceptedStablecoin(address stablecoin, bool accepted) external onlyOwner {
        require(stablecoin != address(0), "Invalid stablecoin address");
        
        // Update mapping
        bool wasAccepted = acceptedStablecoins[stablecoin];
        acceptedStablecoins[stablecoin] = accepted;
        
        // Update array for iteration
        if (accepted && !wasAccepted) {
            // Add to list if newly accepted
            acceptedStablecoinsList.push(stablecoin);
        } else if (!accepted && wasAccepted) {
            // Remove from list if no longer accepted
            for (uint256 i = 0; i < acceptedStablecoinsList.length; i++) {
                if (acceptedStablecoinsList[i] == stablecoin) {
                    // Move last element to this position and pop
                    acceptedStablecoinsList[i] = acceptedStablecoinsList[acceptedStablecoinsList.length - 1];
                    acceptedStablecoinsList.pop();
                    break;
                }
            }
        }
        
        emit AcceptedStablecoinUpdated(stablecoin, accepted);
    }
    
    /// @dev Sets the primary stablecoin for referral payouts (only owner)
    /// @param stablecoin Address of the primary stablecoin (typically USDT)
    function setPrimaryStablecoin(address stablecoin) external onlyOwner {
        require(stablecoin != address(0), "Invalid stablecoin address");
        require(acceptedStablecoins[stablecoin], "Stablecoin not accepted");
        address oldStablecoin = primaryStablecoin;
        primaryStablecoin = stablecoin;
        emit PrimaryStablecoinUpdated(oldStablecoin, stablecoin);
    }

    /// @dev Updates price feed addresses (only owner)
    /// @param _ETHPriceFeed New ETH price feed address
    /// @param _USDTPriceFeed New USDT price feed address
    function setPriceFeed(address _ETHPriceFeed, address _USDTPriceFeed) external onlyOwner {
        require(_ETHPriceFeed != address(0), "Invalid ETH price feed");
        require(_USDTPriceFeed != address(0), "Invalid USDT price feed");

        ETHPriceFeed = AggregatorV3Interface(_ETHPriceFeed);
        USDTPriceFeed = AggregatorV3Interface(_USDTPriceFeed);
        emit PriceFeedsUpdated(_ETHPriceFeed, _USDTPriceFeed);
    }


    /// @dev Withdraws raised funds (stablecoins) with proper distribution
    /// @param tokenAddress Address of token to withdraw
    function withdrawRaisedFunds(address tokenAddress) external onlyOwner {
        require(tokenAddress != address(0), "Invalid token address");
        require(acceptedStablecoins[tokenAddress], "Token not accepted");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance != 0, "No tokens to withdraw");

        // Distribute according to allocation percentages
        uint256 toWalletA = (tokenBalance * walletAPercent) / 10000;
        uint256 toWalletB = (tokenBalance * walletBPercent) / 10000;
        uint256 toTreasury = (tokenBalance * treasuryPercent) / 10000;

        token.safeTransfer(walletA, toWalletA);
        token.safeTransfer(walletB, toWalletB);
        token.safeTransfer(treasuryWallet, toTreasury);
        
        emit FundsDistributed(toWalletA, toWalletB, toTreasury);
    }

    /// @dev Emergency pause function (only owner)
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender);
    }

    /// @dev Unpause the contract (only owner)
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    /// @dev Updates presale timing (only owner, only before presale starts)
    /// @param _startTime New start time
    /// @param _endTime New end time
    function updatePresaleTiming(uint256 _startTime, uint256 _endTime) external onlyOwner {
        require(block.timestamp < startTime, "Presale already started");
        require(_startTime < _endTime, "Invalid timing");
        require(_startTime > block.timestamp, "Start time in future");

        uint256 oldStartTime = startTime;
        uint256 oldEndTime = endTime;
        startTime = _startTime;
        endTime = _endTime;
        emit PresaleTimingUpdated(oldStartTime, oldEndTime, _startTime, _endTime);
    }

    /// @dev Sets referral reward type for a specific round
    /// @param round Round number
    /// @param rewardType USDT or TOKEN reward type
    function setReferralRewardType(uint256 round, RewardType rewardType) external onlyOwner {
        require(round != 0, "Invalid round");
        referralRewardType[round] = rewardType;
    }

    /// @dev Sets current presale round
    /// @param round New round number
    function setCurrentRound(uint256 round) external onlyOwner {
        require(round != 0, "Invalid round");
        RewardType rewardType = _getReferralRewardType(round);
        currentRound = round;
        emit RoundChanged(round, rewardType);
    }

    /// @dev Sets fund routing wallet addresses
    /// @param _walletA Address for 10% allocation
    /// @param _walletB Address for 2% allocation
    /// @param _treasuryWallet Address for 88% allocation
    function setFundWallets(
        address _walletA,
        address _walletB,
        address _treasuryWallet
    ) external onlyOwner {
        require(_walletA != address(0), "Invalid wallet A");
        require(_walletB != address(0), "Invalid wallet B");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        
        walletA = _walletA;
        walletB = _walletB;
        treasuryWallet = _treasuryWallet;
        emit FundWalletsUpdated(_walletA, _walletB, _treasuryWallet);
    }

    /// @dev Configures token vesting schedule
    /// @param cliff Cliff period in seconds
    /// @param duration Total vesting duration in seconds
    /// @param vestingStartTime Vesting start time (0 for after presale ends)
    /// @param revocable Whether vesting can be revoked
    function configureVestingSchedule(
        uint256 cliff,
        uint256 duration,
        uint256 vestingStartTime,
        bool revocable
    ) external onlyOwner {
        require(duration != 0, "Duration must be positive");
        require(cliff < duration + 1, "Cliff exceeds duration");
        
        // Determine the actual vesting start time
        uint256 actualStartTime;
        if (vestingStartTime == 0) {
            // If 0, default to presale end time (not current timestamp)
            actualStartTime = endTime;
        } else {
            actualStartTime = vestingStartTime;
        }
        
        // Critical validation: vesting must start after presale ends
        require(
            actualStartTime >= endTime,
            "Vesting cannot start before presale ends"
        );
        
        // Additional validation: if presale is active, ensure sufficient time gap
        if (block.timestamp <= endTime) {
            // During presale, ensure at least the end time or later
            require(
                actualStartTime >= endTime,
                "Vesting start time must be after presale end time"
            );
        } else {
            // After presale, allow immediate vesting but warn about past dates
            require(
                actualStartTime >= endTime,
                "Vesting start time cannot be before presale ended"
            );
        }
        
        vestingSchedule = VestingSchedule({
            cliff: cliff,
            duration: duration,
            startTime: actualStartTime,
            revocable: revocable
        });
        
        emit VestingConfigured(cliff, duration, vestingSchedule.startTime);
    }

    /// @dev Sets fund distribution percentages (only owner)
    /// @param _walletAPercent Percentage for wallet A (basis points: 1000 = 10%)
    /// @param _walletBPercent Percentage for wallet B (basis points: 200 = 2%)
    /// @param _treasuryPercent Percentage for treasury (basis points: 8800 = 88%)
    function setFundDistributionPercentages(
        uint256 _walletAPercent,
        uint256 _walletBPercent,
        uint256 _treasuryPercent
    ) external onlyOwner {
        require(
            _walletAPercent + _walletBPercent + _treasuryPercent == 10000,
            "Percentages must sum to 100%"
        );
        
        walletAPercent = _walletAPercent;
        walletBPercent = _walletBPercent;
        treasuryPercent = _treasuryPercent;
        emit FundDistributionPercentagesUpdated(_walletAPercent, _walletBPercent, _treasuryPercent);
    }

    /// @dev Authorizes or revokes implementation addresses for upgrades (only owner)
    /// @param implementation Address of the implementation
    /// @param authorized True to authorize, false to revoke
    function setAuthorizedImplementation(address implementation, bool authorized) external onlyOwner {
        require(implementation != address(0), "Invalid implementation addr");
        require(implementation.code.length != 0, "Must be a contract");
        authorizedImplementations[implementation] = authorized;
        emit AuthorizedImplementationUpdated(implementation, authorized);
    }
    
    /// @dev Enables or disables the implementation whitelist (only owner)
    /// @param enabled True to enable whitelist, false to disable
    function setImplementationWhitelistEnabled(bool enabled) external onlyOwner {
        implementationWhitelistEnabled = enabled;
        emit ImplementationWhitelistToggled(enabled);
    }
    
    /// @dev Sets the price feed staleness threshold (only owner)
    /// @param threshold New staleness threshold in seconds (e.g., 24 hours = 86400)
    function setPriceFeedStalenessThreshold(uint256 threshold) external onlyOwner {
        require(threshold != 0, "Threshold must be > 0");
        require(threshold < 7 days + 1, "Threshold too large"); // Maximum 7 days for safety
        uint256 oldThreshold = priceFeedStalenessThreshold;
        priceFeedStalenessThreshold = threshold;
        emit PriceFeedStalenessThresholdUpdated(oldThreshold, threshold);
    }

    // ============ UPGRADE AUTHORIZATION ============

    /// @dev Authorizes contract upgrades (required for UUPS pattern)
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(newImplementation != address(0), "Invalid implementation addr");
        require(newImplementation.code.length != 0, "Must be a contract");
        
        // If whitelist is enabled, check authorization
        if (implementationWhitelistEnabled) {
            require(
                authorizedImplementations[newImplementation], 
                "Implementation not authorized"
            );
        }
        
        // Additional validation: ensure new implementation is different
        require(
            newImplementation != address(this),
            "Cannot upgrade to same implementation"
        );
        
        // Version tracking: ensure new implementation has higher version
        try IVersioned(newImplementation).getVersion() returns (uint256 newVersion) {
            require(newVersion > contractVersion, "Version must be higher");
            // Update contract version after successful upgrade validation
            contractVersion = newVersion;
        } catch {
            revert("Needs version tracking");
        }
    }

    // ============ EMERGENCY FUNCTIONS ============

    /// @dev Emergency function to recover any ERC20 tokens sent by mistake
    /// @param token Address of the token to recover
    /// @param amount Amount to recover
    function emergencyRecoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(token != address(mandalaToken), "Cannot recover sale token");
        require(!acceptedStablecoins[token], "Cannot recover accepted coin");
        
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    /// @dev Returns vesting information for a user
    /// @param user Address to query
    /// @return total Total claimable tokens
    /// @return vested Already vested tokens
    /// @return available Currently available to claim
    function getVestingInfo(address user) external view returns (
        uint256 total,
        uint256 vested,
        uint256 available
    ) {
        total = claimableTokens[user];
        vested = vestedTokens[user];
        available = _calculateVestedAmount(user);
    }

    /// @dev Returns the current contract version for upgrade validation
    /// @return version Current implementation version
    function getVersion() external pure returns (uint256) {
        return 1;
    }

    /// @dev Fallback function to handle calls to non-existent functions
    /// @notice Reverts any call to non-existent functions to prevent unintended ETH acceptance
    fallback() external payable {
        revert("Use buyWithETH()");
    }

    /// @dev Fallback function to handle direct ETH transfers
    receive() external payable {
        revert("Use buyWithETH()");
    }
}
