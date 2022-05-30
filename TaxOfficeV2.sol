// SPDX-License-Identifier: MIT

pragma solidity >=0.8.14;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "./supportContracts/ITaxable.sol";
import "./supportContracts/IUniswapV2Router.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TaxOfficeV2 is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;

    address public HOST;
    address public weth;
    address public uniRouter;

    mapping(address => bool) public taxExclusionEnabled;
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

    // using openzepplin initializer

    function initialize(address _HOST, address _weth, address _uniRouter) public initializer {
        __Ownable_init();
        HOST = _HOST;
        weth = _weth;
                        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);
        uniRouter = _uniRouter;
   
    }

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(HOST).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(HOST).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(HOST).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(HOST).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(HOST).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(HOST).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(HOST).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return _excludeAddressFromTax(_address);
    }

    function _excludeAddressFromTax(address _address) private returns (bool) {
        if (!ITaxable(HOST).isAddressExcluded(_address)) {
            return ITaxable(HOST).excludeAddress(_address);
        }
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return _includeAddressInTax(_address);
    }

    function _includeAddressInTax(address _address) private returns (bool) {
        if (ITaxable(HOST).isAddressExcluded(_address)) {
            return ITaxable(HOST).includeAddress(_address);
        }
    }

    function taxRate() external returns (uint256) {
        return ITaxable(HOST).taxRate();
    }

    function addLiquidityTaxFree(
        address token,
        uint256 amtHOST,
        uint256 amtToken,
        uint256 amtHOSTMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtHOST != 0 && amtToken != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(HOST).transferFrom(msg.sender, address(this), amtHOST);
        IERC20(token).transferFrom(msg.sender, address(this), amtToken);
        _approveTokenIfNeeded(HOST, uniRouter);
        _approveTokenIfNeeded(token, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtHOST;
        uint256 resultAmtToken;
        uint256 liquidity;
        (resultAmtHOST, resultAmtToken, liquidity) = IUniswapV2Router(uniRouter).addLiquidity(
            HOST,
            token,
            amtHOST,
            amtToken,
            amtHOSTMin,
            amtTokenMin,
            msg.sender,
            block.timestamp
        );

        if (amtHOST.sub(resultAmtHOST) > 0) {
            IERC20(HOST).transfer(msg.sender, amtHOST.sub(resultAmtHOST));
        }
        if (amtToken.sub(resultAmtToken) > 0) {
            IERC20(token).transfer(msg.sender, amtToken.sub(resultAmtToken));
        }
        return (resultAmtHOST, resultAmtToken, liquidity);
    }

    function addLiquidityAVAXTaxFree(
        uint256 amtHOST,
        uint256 amtHOSTMin,
        uint256 amtEthMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtHOST != 0 && msg.value != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(HOST).transferFrom(msg.sender, address(this), amtHOST);
        _approveTokenIfNeeded(HOST, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtHOST;
        uint256 resultAmtEth;
        uint256 liquidity;
        (resultAmtHOST, resultAmtEth, liquidity) = IUniswapV2Router(uniRouter).addLiquidityAVAX{value: msg.value}(
            HOST,
            amtHOST,
            amtHOSTMin,
            amtEthMin,
            msg.sender,
            block.timestamp
        );

        if (amtHOST.sub(resultAmtHOST) > 0) {
            IERC20(HOST).transfer(msg.sender, amtHOST.sub(resultAmtHOST));
        }
        return (resultAmtHOST, resultAmtEth, liquidity);
    }

    function setTaxableHOSTOracle(address _HOSTOracle) external onlyOperator {
        ITaxable(HOST).setHOSTOracle(_HOSTOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(HOST).setTaxOffice(_newTaxOffice);
    }

    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external {
        require(taxExclusionEnabled[msg.sender], "Address not approved for tax free transfers");
        _excludeAddressFromTax(_sender);
        IERC20(HOST).transferFrom(_sender, _recipient, _amt);
        _includeAddressInTax(_sender);
    }

    function setTaxExclusionForAddress(address _address, bool _excluded) external onlyOperator {
        taxExclusionEnabled[_address] = _excluded;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), _router) == 0) {
            IERC20(_token).approve(_router, type(uint256).max);
        }
    }
}