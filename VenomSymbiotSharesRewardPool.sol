// SPDX-License-Identifier: MIT
// Venom-Finance v7

pragma solidity >=0.8.14;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract VShareRewardPool  is Initializable, OwnableUpgradeable  {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // operator
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. tSHAREs to distribute per block.
        uint256 lastRewardTime; // Last time that tSHAREs distribution occurs.
        uint256 accSymbiotPerShare; // Accumulated tSHAREs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IERC20 public bshare;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The time when tSHARE mining starts.
    uint256 public poolStartTime;

    // The time when tSHARE mining ends.
    uint256 public poolEndTime;

    uint256 public tSharePerSecond; // 60000 SYMBIOT / (370 days * 24h * 60min * 60s)
    uint256 public runningTime; // 370 days
    uint256 public TOTAL_REWARDS;
    bool public ReentrantOn; 
    bool public isHumanOn; 
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    // Reentrant guard    
    function setReentrant(bool _ReentrantOn) public onlyOwner { 
        ReentrantOn = _ReentrantOn; 
        }

    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED || !ReentrantOn, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    // isHuman to prevent attack from other contracts

    function setIsHuman(bool _isHumanOn) public onlyOwner { 
        isHumanOn = _isHumanOn; 
        }

    modifier isHuman() {
            require(tx.origin == msg.sender || !isHumanOn, "sorry humans only" )  ;
            _;
        }

    // using openzepplin initializer
     function initialize(address _bshare, uint256 _poolStartTime) public initializer {
        __Ownable_init();
        if (_bshare != address(0)) bshare = IERC20(_bshare);
        runningTime = 370 days;
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        operator = msg.sender;
        tSharePerSecond = 0.001876876 ether;
        totalAllocPoint = 0;
        isHumanOn = true; 
        ReentrantOn = true; 
        TOTAL_REWARDS = 60000 ether;
        _status = _NOT_ENTERED;
   
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "VShareRewardPool: caller is not the operator");
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "VShareRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _token, bool _withUpdate, uint256 _lastRewardTime) public onlyOperator {    

        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted =
        (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accSymbiotPerShare : 0,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's tSHARE allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(tSharePerSecond);
            return poolEndTime.sub(_fromTime).mul(tSharePerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(tSharePerSecond);
            return _toTime.sub(_fromTime).mul(tSharePerSecond);
        }
    }

    // View function to see pending tSHAREs on frontend.
    function pendingShare(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSymbiotPerShare = pool.accSymbiotPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _bshareReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSymbiotPerShare = accSymbiotPerShare.add(_bshareReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSymbiotPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _bshareReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSymbiotPerShare = pool.accSymbiotPerShare.add(_bshareReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }


    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public isHuman nonReentrant{
        address _sender = msg.sender;
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
  

        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSymbiotPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeSymbiotTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSymbiotPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public isHuman nonReentrant{
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accSymbiotPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeSymbiotTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSymbiotPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public isHuman nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe bshare transfer function, just in case if rounding error causes pool to not have enough tSHAREs.
    function safeSymbiotTransfer(address _to, uint256 _amount) internal {
        uint256 _bshareBal = bshare.balanceOf(address(this));
        if (_bshareBal > 0) {
            if (_amount > _bshareBal) {
                bshare.safeTransfer(_to, _bshareBal);
            } else {
                bshare.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 360 days) {
            // do not allow to drain core token (tSHARE or lps) if less than 360 days after pool ends
            require(_token != bshare, "bshare");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}