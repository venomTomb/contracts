// SPDX-License-Identifier: MIT

pragma solidity >=0.8.14;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Note that this pool has no minter key of HOST (rewards).
// Instead, the governance will call HOST distributeReward method and send reward to this pool at the beginning.
contract VTombGenesisRewardPool is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;


// Reentrant guard

    bool public ReentrantOn; 

    function setReentrant(bool _ReentrantOn) public onlyOwner { 
        ReentrantOn = _ReentrantOn; 
        }

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

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
    // governance
    address public operator;
    address public feeAddress;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. HOST to distribute.
        uint256 lastRewardTime; // Last time that HOST distribution occurs.
        uint16  depositFeeBP; //depositfee
        uint256 accHOSTPerShare; // Accumulated HOST per share, times 1e18. See below.
        bool isStarted; // if lastRewardBlock has passed
    }

    IERC20 public HOST;
    address public cake;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The time when HOST mining starts.
    uint256 public poolStartTime;

    // The time when HOST mining ends.
    uint256 public poolEndTime;

    // TESTNET
    // uint256 public HOSTPerSecond = 3.0555555 ether; // 11000 HOST / (1h * 60min * 60s)
    // uint256 public runningTime = 24 hours; // 1 hours
    // uint256 public constant TOTAL_REWARDS = 11000 ether;
    // END TESTNET

    // MAINNET
    uint256 public HOSTPerSecond; // 45000 HOST / (2*24h * 60min * 60s)
    uint256 public runningTime; // 2 days
    uint256 public constant TOTAL_REWARDS = 45000 ether;
    // END MAINNET

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    
    bool public feeCheckerFunctionsDisabled;
    bool public feeChecker;
    bool public isHumanOn; 

    function setIsHuman(bool _isHumanOn) public onlyOwner { 
        isHumanOn = _isHumanOn; 
        }

    modifier isHuman() {
            require(tx.origin == msg.sender || !isHumanOn, "sorry humans only" )  ;
            _;
        }

     /* ========== TEST FUNCTIONS ========== */
    
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
    
    // These function cant never be used if functionsDisabled is set to true

    function setStartRunningTime(uint256 _poolStartTime, uint256 _runningTime) public onlyOwner disable { 
            poolStartTime = _poolStartTime; 
            runningTime = _runningTime;
            poolEndTime = poolStartTime + runningTime;
        }

    function setCakeHost(address _cake, address _HOST) public onlyOwner disable { 
            cake = _cake;
            HOST = IERC20(_HOST);
        }

    function setHostPerSecond(uint256 _HOSTPerSecond) public onlyOwner disable { 
            HOSTPerSecond = _HOSTPerSecond;
        }

     /* ========== TEST FUNCTIONS END ========== */

    // using openzepplin initializer

    function initialize(address _HOST,address _cake,address _feeAddress,uint256 _poolStartTime) public initializer {
        __Ownable_init();
        if (_HOST != address(0)) HOST = IERC20(_HOST);
        if (_cake != address(0)) cake = _cake;
        runningTime = 2 days;
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        operator = msg.sender;
        functionsDisabled = false;
        feeAddress = _feeAddress;
        totalAllocPoint = 0;
        HOSTPerSecond = 0.2604 ether;
        isHumanOn = true; 
        _status = _NOT_ENTERED;
        ReentrantOn = true; 
   
    }
    modifier onlyOperator() {
        require(operator == msg.sender, "HOSTGenesisPool: caller is not the operator");
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "HOSTGenesisPool: existing pool?");
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime,
        uint16  _depositFeeBP

    ) public onlyOperator {
        require(_depositFeeBP <= 400, "add: invalid deposit fee basis points");

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
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({token: _token, allocPoint: _allocPoint, lastRewardTime: _lastRewardTime, accHOSTPerShare: 0, isStarted: _isStarted, depositFeeBP: _depositFeeBP}));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's HOST allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint,  uint16 _depositFeeBP) public onlyOperator {
        require(_depositFeeBP <= 400, "set: invalid deposit fee basis points");
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(HOSTPerSecond);
            return poolEndTime.sub(_fromTime).mul(HOSTPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(HOSTPerSecond);
            return _toTime.sub(_fromTime).mul(HOSTPerSecond);
        }
    }

    // View function to see pending HOST on frontend.
    function pendingHOST(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accHOSTPerShare = pool.accHOSTPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _HOSTReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accHOSTPerShare = accHOSTPerShare.add(_HOSTReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accHOSTPerShare).div(1e18).sub(user.rewardDebt);
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
            uint256 _HOSTReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accHOSTPerShare = pool.accHOSTPerShare.add(_HOSTReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    modifier disableFeeChecker() {
            require(!feeCheckerFunctionsDisabled, "function is permantly disabled!" )  ;
            _;
        }
    
    // disable the function setFeeChecker
    function disableFeeCheckerFunctions() public onlyOwner { 
            feeCheckerFunctionsDisabled = true; 
        }

    function setFeeChecker(bool falseForOn) public onlyOwner disableFeeChecker  { 
            feeChecker = falseForOn; 
        }
    
    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount)  public isHuman nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        
    // checking for transfer fee by sending 1000 wei from and to the user
    if (feeChecker == false){

    uint256 _totalTokenBefore = IERC20(pool.token).balanceOf(msg.sender); 
    pool.token.safeTransferFrom(msg.sender, msg.sender, 1000);
    uint256 _totalTokenAfter = IERC20(pool.token).balanceOf(msg.sender);
    require(_totalTokenBefore == _totalTokenAfter, "token with fees not allowed!" );
        }

       
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accHOSTPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeHOSTTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            if (address(pool.token) == cake) {
                user.amount = user.amount.add(_amount.mul(9900).div(10000));
            } 
             if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.token.safeTransfer(feeAddress, depositFee);
                // pool.lpToken.safeTransfer(vaultAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            }else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accHOSTPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public isHuman nonReentrant{
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accHOSTPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeHOSTTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accHOSTPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public isHuman nonReentrant{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe HOST transfer function, just in case if rounding error causes pool to not have enough HOSTs.
    function safeHOSTTransfer(address _to, uint256 _amount) internal {
        uint256 _HOSTBalance = HOST.balanceOf(address(this));
        if (_HOSTBalance > 0) {
            if (_amount > _HOSTBalance) {
                HOST.safeTransfer(_to, _HOSTBalance);
            } else {
                HOST.safeTransfer(_to, _amount);
            }
        }
    }

    function setFeeAddress(address _feeAddress) external onlyOperator {
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyOperator {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (HOST or lps) if less than 90 days after pool ends
            require(_token != HOST, "HOST");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}