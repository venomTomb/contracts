// SPDX-License-Identifier: MIT

pragma solidity >=0.8.14;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./supportContracts/Operator.sol";

contract SymbiotShare is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 60,000 tSHAREs
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 60000 ether;
    uint256 public constant COMMUNITY_FUND_POOL_ALLOCATION = 5000 ether;
    uint256 public constant DEV_FUND_POOL_ALLOCATION = 5000 ether;
    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public communityFundRewardRate;
    uint256 public devFundRewardRate;
    address public communityFund;
    address public devFund;
    uint256 public communityFundLastClaimed;
    uint256 public devFundLastClaimed;
    bool public rewardPoolDistributed = false;
    
     /* ============================== TEST FUNCTIONS ============================== */
    
    bool public functionsDisabled;

    modifier disable() {
            require(!functionsDisabled, "function is permantly disabled!" )  ;
            _;
        }
    
    // disable all functions with the modifier disable, this can not be undone

    function disableFunctions() public onlyOwner { 
            require(!functionsDisabled);
            functionsDisabled = true; 
        }
    
    // This function cant never be used if functionsDisabled is set to true

    function setStartTime(uint256 _startTime) public onlyOwner disable { 
            startTime = _startTime; 
            endTime = startTime + VESTING_DURATION;

            communityFundLastClaimed = startTime;
            devFundLastClaimed = startTime;


        }

     /* ============================== TEST FUNCTIONS END ============================== */

    constructor(address _communityFund, address _devFund,uint256 _startTime) ERC20("SYMBIOT", "SYMBIOT") {
        _mint(msg.sender, 1 ether); // mint 1 HOST Share for initial pools deployment

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        communityFundLastClaimed = startTime;
        devFundLastClaimed = startTime;

        communityFundRewardRate = COMMUNITY_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        devFundRewardRate = DEV_FUND_POOL_ALLOCATION.div(VESTING_DURATION);

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_communityFund != address(0), "Address cannot be 0");
        communityFund = _communityFund;
    }

    function setTreasuryFund(address _communityFund) external {
        require(msg.sender == devFund, "!dev");
        communityFund = _communityFund;
    }

    function setDevFund(address _devFund) external {
        require(msg.sender == devFund, "!dev");
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function unclaimedTreasuryFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (communityFundLastClaimed >= _now) return 0;
        _pending = _now.sub(communityFundLastClaimed).mul(communityFundRewardRate);
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (devFundLastClaimed >= _now) return 0;
        _pending = _now.sub(devFundLastClaimed).mul(devFundRewardRate);
    }

    /**
     * @dev Claim pending rewards to community and dev fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedTreasuryFund();
        if (_pending > 0 && communityFund != address(0)) {
            _mint(communityFund, _pending);
            communityFundLastClaimed = block.timestamp;
        }
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            _mint(devFund, _pending);
            devFundLastClaimed = block.timestamp;
        }
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    
     function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}