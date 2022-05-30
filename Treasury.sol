// SPDX-License-Identifier: MIT
// Venom-Finance v2

pragma solidity >=0.8.14;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "./supportContracts/Operator.sol";
import "./supportContracts/Math.sol";
import "./supportContracts/Babylonian.sol";
import "./supportContracts/ContractGuard.sol";
import "./supportContracts/IBasisAsset.sol";
import "./supportContracts/IOracle.sol";
import "./supportContracts/IBoardroom.sol";

contract Treasury is ContractGuard, Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // epoch
    uint256 public startTime;
    uint256 public epoch;
    uint256 public epochSupplyContractionLeft;

    // exclusions from total supply
    address[] public excludedFromTotalSupply;

    // core components
    address public HOST;
    address public bbond;
    address public bshare;

    address public boardroom;
    address public HOSTOracle;

    // price
    uint256 public HOSTPriceOne;
    uint256 public HOSTPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of HOST price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochHOSTPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra HOST during debt phase
    bool public isHumanOn; 
    bool public functionsDisabled;
    
    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 HOSTAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 HOSTAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(block.timestamp >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(block.timestamp >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getHOSTPrice() > HOSTPriceCeiling) ? 0 : getHOSTCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(HOST).operator() == address(this) &&
                IBasisAsset(bbond).operator() == address(this) &&
                IBasisAsset(bshare).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getHOSTPrice() public view returns (uint256 HOSTPrice) {
        try IOracle(HOSTOracle).consult(HOST, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult HOST price from the oracle");
        }
    }

    function getHOSTUpdatedPrice() public view returns (uint256 _HOSTPrice) {
        try IOracle(HOSTOracle).twap(HOST, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult HOST price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableHOSTLeft() public view returns (uint256 _burnableHOSTLeft) {
        uint256 _HOSTPrice = getHOSTPrice();
        if (_HOSTPrice <= HOSTPriceOne) {
            uint256 _HOSTSupply = getHOSTCirculatingSupply();
            uint256 _bondMaxSupply = _HOSTSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableHOST = _maxMintableBond.mul(_HOSTPrice).div(HOSTPriceOne);
                _burnableHOSTLeft = Math.min(epochSupplyContractionLeft, _maxBurnableHOST);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _HOSTPrice = getHOSTPrice();
        if (_HOSTPrice > HOSTPriceCeiling) {
            uint256 _totalHOST = IERC20(HOST).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalHOST.mul(HOSTPriceOne).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _HOSTPrice = getHOSTPrice();
        if (_HOSTPrice <= HOSTPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = HOSTPriceOne;
            } else {
                uint256 _bondAmount = HOSTPriceOne.mul(1e18).div(_HOSTPrice); // to burn 1 HOST
                uint256 _discountAmount = _bondAmount.sub(HOSTPriceOne).mul(discountPercent).div(10000);
                _rate = HOSTPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _HOSTPrice = getHOSTPrice();
        if (_HOSTPrice > HOSTPriceCeiling) {
            uint256 _HOSTPricePremiumThreshold = HOSTPriceOne.mul(premiumThreshold).div(100);
            if (_HOSTPrice >= _HOSTPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _HOSTPrice.sub(HOSTPriceOne).mul(premiumPercent).div(10000);
                _rate = HOSTPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = HOSTPriceOne;
            }
        }
    }

    // isHuman to prevent contract calls to functions
    
    function setIsHuman(bool _isHumanOn) public onlyOwner { 
        isHumanOn = _isHumanOn; 
        }

    modifier isHuman() {
            require(tx.origin == msg.sender || !isHumanOn, "sorry humans only" )  ;
            _;
        }


    /* ========== TEST FUNCTIONS ========== */

    modifier disable() {
            require(!functionsDisabled, "function is permantly disabled!" )  ;
            _;
        }
    
    // Theses function cant never be used if functionsDisabled is set to true
    function disableFunctions() public onlyOwner { 
            functionsDisabled = true; 
        }

    function setStartTime(uint256 _startTime) public onlyOwner disable { 
            startTime = _startTime; 
        }

    function setTokens(address _HOST, address _bbond,address _bshare) public onlyOwner disable { 
        HOST = _HOST;
        bbond = _bbond;
        bshare = _bshare;
    }

     /* ========== TEST FUNCTIONS END ========== */

    // using openzepplin modifier
    
    function initialize(address _HOST, address _bbond, address _bshare, uint256 _startTime) public initializer {
         __Ownable_init();
        HOST = _HOST;
        bbond = _bbond;
        bshare = _bshare;
        startTime = _startTime;
        epochSupplyContractionLeft = 0;
        HOSTPriceOne = 1 * 1e18; // This is to allow a PEG of 1 HOST per DAI
        HOSTPriceCeiling = HOSTPriceOne.mul(101).div(100);
        epoch = 0;
        isHumanOn = true; 
        // Dynamic max expansion percent
        supplyTiers = [0 ether, 250000 ether, 500000 ether, 750000 ether, 1000000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 200, 150, 125, 100, 100];
         // Upto 4.5% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn HOST and mint tBOND)
        maxDebtRatioPercent = 4500; // Upto 35% supply of tBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 0;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(HOST).balanceOf(address(this));


        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setHOSTOracle(address _HOSTOracle) external onlyOperator {
        HOSTOracle = _HOSTOracle;
    }

    function setHOSTPriceCeiling(uint256 _HOSTPriceCeiling) external onlyOperator {
        require(_HOSTPriceCeiling >= HOSTPriceOne && _HOSTPriceCeiling <= HOSTPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        HOSTPriceCeiling = _HOSTPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= HOSTPriceCeiling, "_premiumThreshold exceeds HOSTPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateHOSTPrice() internal {
        try IOracle(HOSTOracle).update() {} catch {}
    }

    function getHOSTCirculatingSupply() public view returns (uint256) {
        IERC20 HOSTErc20 = IERC20(HOST);
        uint256 totalSupply = HOSTErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(HOSTErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _HOSTAmount, uint256 targetPrice) external isHuman onlyOneBlock checkCondition checkOperator {
        require(_HOSTAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 HOSTPrice = getHOSTPrice();
        require(HOSTPrice == targetPrice, "Treasury: HOST price moved");
        require(
            HOSTPrice < HOSTPriceOne, // price < $1
            "Treasury: HOSTPrice not eligible for bond purchase"
        );

        require(_HOSTAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _HOSTAmount.mul(_rate).div(HOSTPriceOne);
        uint256 HOSTSupply = getHOSTCirculatingSupply();
        uint256 newBondSupply = IERC20(bbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= HOSTSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(HOST).burnFrom(msg.sender, _HOSTAmount);
        IBasisAsset(bbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_HOSTAmount);
        _updateHOSTPrice();

        emit BoughtBonds(msg.sender, _HOSTAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external isHuman onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 HOSTPrice = getHOSTPrice();
        require(HOSTPrice == targetPrice, "Treasury: HOST price moved");
        require(
            HOSTPrice > HOSTPriceCeiling, // price > $1.01
            "Treasury: HOSTPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _HOSTAmount = _bondAmount.mul(_rate).div(HOSTPriceOne);
        require(IERC20(HOST).balanceOf(address(this)) >= _HOSTAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _HOSTAmount));

        IBasisAsset(bbond).burnFrom(msg.sender, _bondAmount);
        IERC20(HOST).safeTransfer(msg.sender, _HOSTAmount);

        _updateHOSTPrice();

        emit RedeemedBonds(msg.sender, _HOSTAmount, _bondAmount);
    }

    function _sendToBoardroom(uint256 _amount) internal {
        IBasisAsset(HOST).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(HOST).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(block.timestamp, _daoFundSharedAmount);
    }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(HOST).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(block.timestamp, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(HOST).safeApprove(boardroom, 0);
        IERC20(HOST).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(block.timestamp, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _HOSTSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_HOSTSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateHOSTPrice();
        previousEpochHOSTPrice = getHOSTPrice();
        uint256 HOSTSupply = getHOSTCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToBoardroom(HOSTSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochHOSTPrice > HOSTPriceCeiling) {
                // Expansion ($HOST Price > 1 $AVAX): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bbond).totalSupply();
                uint256 _percentage = previousEpochHOSTPrice.sub(HOSTPriceOne).mul(1000);
                uint256 _savedForBond;
                uint256 _savedForBoardroom;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(HOSTSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = HOSTSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = HOSTSupply.mul(_percentage).div(1e18);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_savedForBoardroom);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(HOST).mint(address(this), _savedForBond);
                    emit TreasuryFunded(block.timestamp, _savedForBond);
                }
            }
        }
    }
    	
    function _simulateMaxSupplyExpansionPercent(uint256 _HOSTSupply) internal view returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_HOSTSupply >= supplyTiers[tierId]) {
                return maxExpansionTiers[tierId];
            }
        }
        return 0;
    }

    function simulateSeigniorage() public view returns (uint256 _savedForBond, uint256 _savedForBoardroom) {
        uint256 _previousEpochHOSTPrice = getHOSTPrice();
        uint256 HOSTSupply = getHOSTCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _savedForBoardroom = HOSTSupply.mul(bootstrapSupplyExpansionPercent).div(10000);
        } else {
            if (_previousEpochHOSTPrice > HOSTPriceCeiling) {
                // Expansion ($TOMB Price > 1 $FTM): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bbond).totalSupply();
                uint256 _percentage = _previousEpochHOSTPrice.sub(HOSTPriceOne).mul(1000);
                uint256 _mse = _simulateMaxSupplyExpansionPercent(HOSTSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = HOSTSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = HOSTSupply.mul(_percentage).div(1e18);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    //_sendToMasonry(_savedForMasonry);
                }
                if (_savedForBond > 0) {
                    //seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    //IBasisAsset(tomb).mint(address(this), _savedForBond);
                    //emit TreasuryFunded(block.timestamp, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(HOST), "HOST");
        require(address(_token) != address(bbond), "bond");
        require(address(_token) != address(bshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function setExcludedFromTotalSupply(address[] memory _excluded) external onlyOperator {
        excludedFromTotalSupply = _excluded;
    }

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}