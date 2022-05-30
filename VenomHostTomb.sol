 // SPDX-License-Identifier: MIT

pragma solidity >=0.8.14;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./supportContracts/Math.sol";
import "./supportContracts/SafeMath8.sol";
import "./supportContracts/IOracle.sol";

contract VenomHostTomb is ERC20Burnable {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Initial distribution for the first 72h genesis pools
    uint256 public constant INITIAL_GENESIS_POOL_DISTRIBUTION = 45000 ether;
  
    // Distribution for airdrops wallet
    uint256 public constant INITIAL_AIRDROP_WALLET_DISTRIBUTION = 5000 ether;

    // Have the rewards Vhostn distributed to the pools
    bool public rewardPoolDistributed = false;

    /* ================= Taxation =============== */
    // Address of the Oracle
    address public VhostOracle;
    // Address of the Tax Office
    address public taxOffice;
 
    // Current tax rate
    uint256 public taxRate;
    // Price threshold below which taxes will get burned
    uint256 public burnThreshold = 1.10e18;
    // Address of the tax collector wallet
    address public taxCollectorAddress;

    // Should the taxes be calculated using the tax tiers
    bool public autoCalculateTax;

    // Tax Tiers
    uint256[] public taxTiersTwaps = [0, 5e17, 6e17, 7e17, 8e17, 9e17, 9.5e17, 1e18, 1.05e18, 1.10e18, 1.20e18, 1.30e18, 1.40e18, 1.50e18];
    uint256[] public taxTiersRates = [2000, 1900, 1800, 1700, 1600, 1500, 1500, 1500, 1500, 1400, 900, 400, 200, 100];

    // Sender addresses excluded from Tax
    mapping(address => bool) public excludedAddresses;

    event TaxOfficeTransferred(address oldAddress, address newAddress);

    modifier onlyTaxOffice() {
        require(taxOffice == msg.sender, "Caller is not the tax office");
        _;
    }

    modifier onlyOperatorOrTaxOffice() {
        require(isOperator() || taxOffice == msg.sender, "Caller is not the operator or the tax office");
        _;
    }
    address private _operator;

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);


    function operator() public view returns (address) {
        return _operator;
    }

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    function isOperator() public view returns (bool) {
        return _msgSender() == _operator;
    }

    function transferOperator(address newOperator_) public onlyOperator {
        _transferOperator(newOperator_);
    }

    function _transferOperator(address newOperator_) internal {
        require(newOperator_ != address(0), "operator: zero address given for new operator");
        emit OperatorTransferred(address(0), newOperator_);
        _operator = newOperator_;
    }
    /**
     * @notice Constructs the HOST ERC-20 contract.
     */
    constructor(uint256 _taxRate, address _taxCollectorAddress) ERC20("HOST", "HOST") {
        // Mints 1 HOST to contract creator for initial pool setup
        require(_taxRate < 2100, "tax equal or bigger to 21%");
        require(_taxCollectorAddress != address(0), "tax collector address must be non-zero address");
        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);
        taxRate = _taxRate;
        taxCollectorAddress = _taxCollectorAddress;
        excludeAddress(address(this));
        _mint(msg.sender, 1 ether);
    }

    /* ============= Taxation ============= */

    function getTaxTiersTwapsCount() public view returns (uint256 count) {
        return taxTiersTwaps.length;
    }

    function getTaxTiersRatesCount() public view returns (uint256 count) {
        return taxTiersRates.length;
    }

    function isAddressExcluded(address _address) public view returns (bool) {
        return excludedAddresses[_address];
    }

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyTaxOffice returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < getTaxTiersTwapsCount(), "Index has to lower than count of tax tiers");
        if (_index > 0) {
            require(_value > taxTiersTwaps[_index - 1]);
        }
        if (_index < getTaxTiersTwapsCount().sub(1)) {
            require(_value < taxTiersTwaps[_index + 1]);
        }
        taxTiersTwaps[_index] = _value;
        return true;
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyTaxOffice returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < getTaxTiersRatesCount(), "Index has to lower than count of tax tiers");
        taxTiersRates[_index] = _value;
        return true;
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyTaxOffice returns (bool) {
        burnThreshold = _burnThreshold;
    }

    function _getVenomHostTombPrice() internal view returns (uint256 _VhostPrice) {
        try IOracle(VhostOracle).consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("VenomHostTomb: failed to fetch HOST price from Oracle");
        }
    }

    function _updateTaxRate(uint256 _VhostPrice) internal returns (uint256) {
        if (autoCalculateTax) {
            for (uint8 tierId = uint8(getTaxTiersTwapsCount()).sub(1); tierId >= 0; --tierId) {
                if (_VhostPrice >= taxTiersTwaps[tierId]) {
                    require(taxTiersRates[tierId] < 2100, "tax equal or bigger to 21%");
                    taxRate = taxTiersRates[tierId];
                    return taxTiersRates[tierId];
                }
            }
        }
    }

    function enableAutoCalculateTax() public onlyTaxOffice {
        autoCalculateTax = true;
    }

    function disableAutoCalculateTax() public onlyTaxOffice {
        autoCalculateTax = false;
    }

    function setVenomHostTombOracle(address _VhostOracle) public onlyOperatorOrTaxOffice {
        require(_VhostOracle != address(0), "oracle address cannot be 0 address");
        VhostOracle = _VhostOracle;
    }

    function setTaxOffice(address _taxOffice) public onlyOperatorOrTaxOffice {
        require(_taxOffice != address(0), "tax office address cannot be 0 address");
        emit TaxOfficeTransferred(taxOffice, _taxOffice);
        taxOffice = _taxOffice;
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyTaxOffice {
        require(_taxCollectorAddress != address(0), "tax collector address must be non-zero address");
        taxCollectorAddress = _taxCollectorAddress;
    }

    function setTaxRate(uint256 _taxRate) public onlyTaxOffice {
        require(!autoCalculateTax, "auto calculate tax cannot be enabled");
        require(_taxRate < 2100, "tax equal or bigger to 21%");
        taxRate = _taxRate;
    }

    function excludeAddress(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(!excludedAddresses[_address], "address can't be excluded");
        excludedAddresses[_address] = true;
        return true;
    }

    function includeAddress(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(excludedAddresses[_address], "address can't be included");
        excludedAddresses[_address] = false;
        return true;
    }

    /**
     * @notice Operator mints HOST to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of HOST to mint to
     * @return whether the process has Vhostn done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        uint256 currentTaxRate = 0;
        bool burnTax = false;

        if (autoCalculateTax) {
            uint256 currentVenomHostTombPrice = _getVenomHostTombPrice();
            currentTaxRate = _updateTaxRate(currentVenomHostTombPrice);
            if (currentVenomHostTombPrice < burnThreshold) {
                burnTax = true;
            }
        }

        if (currentTaxRate == 0 || excludedAddresses[sender]) {
            _transfer(sender, recipient, amount);
        } else {
            _transferWithTax(sender, recipient, amount, burnTax);
        }

        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function _transferWithTax(
        address sender,
        address recipient,
        uint256 amount,
        bool burnTax
    ) internal returns (bool) {
        uint256 taxAmount = amount.mul(taxRate).div(10000);
        uint256 amountAfterTax = amount.sub(taxAmount);

        if (burnTax) {
            // Burn tax
            super.burnFrom(sender, taxAmount);
        } else {
            // Transfer tax to tax collector
            _transfer(sender, taxCollectorAddress, taxAmount);
        }

        // Transfer amount after tax to recipient
        _transfer(sender, recipient, amountAfterTax);

        return true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _genesisPool,
        address _airdropWallet
    ) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_genesisPool != address(0), "!_genesisPool");
        require(_airdropWallet != address(0), "!_airdropWallet");
        rewardPoolDistributed = true;
        _mint(_genesisPool, INITIAL_GENESIS_POOL_DISTRIBUTION);
        _mint(_airdropWallet, INITIAL_AIRDROP_WALLET_DISTRIBUTION);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}