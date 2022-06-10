// SPDX-License-Identifier: MIT
// Venom-Finance final version 2.0 2.0
// https://t.me/VenomFinanceCommunity

pragma solidity >=0.8.14;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Note that this pool has no minter key of HOST (rewards).
// Instead, the governance will call HOST distributeReward method and send reward to this pool at the beginning.


// Note that this pool has no minter key of HOST (rewards).
// Instead, the governance will call HOST distributeReward method and send reward to this pool at the beginning.
contract VTombGenesisRewardPool is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

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
        uint256 accHOSTPerShare; // Accumulated HOST per share, times 1e18. See below.
        bool isStarted; // if lastRewardBlock has passed
    }


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

    IERC20 public HOST;
    address public cake;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when HOST mining starts.
    uint256 public poolStartTime;

    // The time when HOST mining ends.
    uint256 public poolEndTime;

    uint public daoFee;
    address public daoAddress;

    bool public isHumanOn; 

    function setIsHuman(bool _isHumanOn) public onlyOwner { 
        isHumanOn = _isHumanOn; 
        }

    modifier isHuman() {
            require(tx.origin == msg.sender || !isHumanOn, "sorry humans only" )  ;
            _;
        }
    // MAINNET
     uint256 public HOSTPerSecond = 0.231481 ether; // 60000 HOST / (3*(24h * 60min * 60s)) 0.231481
     uint256 public runningTime = 3 days; // 3 days
    // END MAINNET

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    function initialize(address _HOST,address _cake,uint256 _poolStartTime) public initializer {
        __Ownable_init();
        if (_HOST != address(0)) HOST = IERC20(_HOST);
        if (_cake != address(0)) cake = _cake;
        feeLessTokens[cake] = true;
        runningTime = 3 days;
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        operator = msg.sender;
        totalAllocPoint = 0;
        isHumanOn = true; 
        _status = _NOT_ENTERED;
        ReentrantOn = true; 
        daoFee = 200;
        daoAddress = msg.sender;

   
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
        uint256 _lastRewardTime
    ) public onlyOperator {
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
            accHOSTPerShare : 0,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's HOST allocation point. Can only be called by the owner.
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


        mapping(address => bool) public feeLessTokens;

    function addfeeLessToken(address _address, bool value) public onlyOwner {
    feeLessTokens[_address] = value;
    }


    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public isHuman nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);

        // if not a feeLess token, account for fee
        if (feeLessTokens[address(pool.token)] == false) {

        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accHOSTPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeHOSTTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);

            uint _fee = _amount.mul( daoFee ).div( 10000 );
            pool.token.safeTransfer(daoAddress, _fee);
            uint256 _amountSubFee = _amount.sub(_fee);

            if(address(pool.token) == cake) {
                user.amount = user.amount.add(_amountSubFee.mul(cakeTokenFee).div(10000));
            } else {
                user.amount = user.amount.add(_amountSubFee);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accHOSTPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount); }

        // if token is feeLess

        else  {
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accHOSTPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeHOSTTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);

            uint _fee = 0;
            // pool.token.safeTransfer(daoAddress, _fee);
            uint256 _amountSubFee = _amount.sub(_fee);
            if(address(pool.token) == cake) {
                user.amount = user.amount.add(_amountSubFee.mul(cakeTokenFee).div(10000));
            } else {
                user.amount = user.amount.add(_amountSubFee);
            }
            }
            user.rewardDebt = user.amount.mul(pool.accHOSTPerShare).div(1e18);
            emit Deposit(_sender, _pid, _amount); }
    }

    uint256 public cakeTokenFee = 10000;

    // function setCakeTokenFee(uint256 _cakeFee) public onlyOwner returns (uint256){
    //     require(_cakeFee <= 20 || _cakeFee >= 0, "Max fee 20%");
    //     uint256 feeToMath = (100 - _cakeFee) * 100;
    //     cakeTokenFee = feeToMath;
    //     return cakeTokenFee;

    // }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public isHuman nonReentrant {
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
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe HOST transfer function, just in case if rounding error causes pool to not have enough HOST.
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

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setDaoFee(address _address, uint _fee) external onlyOperator {
        require(_fee <= 200, "Max fee 2%");
        daoAddress = _address;
        daoFee = _fee;
    }


}