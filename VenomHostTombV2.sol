// SPDX-License-Identifier: MIT
// Venom-Finance final version 2.0
// https://t.me/VenomFinanceCommunity

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
import "./supportContracts/Operator.sol";

contract VenomHostTombV2 is ERC20Burnable, Ownable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Initial distribution for the first 72h genesis pools
    uint256 public constant INITIAL_GENESIS_POOL_DISTRIBUTION = 60000 ether;  // 60000 HOST / (3*(24h * 60min * 60s)) 0.231481
  
    // Distribution for airdrops wallet
    uint256 public constant INITIAL_AIRDROP_WALLET_DISTRIBUTION = 5000 ether;

    // Have the rewards Vhostn distributed to the pools
    bool public rewardPoolDistributed = false;

    /* ================= Taxation =============== */
    // Address of the Oracle
    address public VhostOracle;

    /**
     * @notice Constructs the HOST ERC-20 contract.
     */
    constructor() ERC20("HOST", "HOST") {
        // Mints 1 HOST to contract creator for initial pool setup
        _mint(msg.sender, 1 ether);
    }

    function _getVenomHostTombPrice() internal view returns (uint256 _VhostPrice) {
        try IOracle(VhostOracle).consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("VenomHostTomb: failed to fetch HOST price from Oracle");
        }
    }
    function setVenomHostTombOracle(address _VhostOracle) public onlyOwner {
        require(_VhostOracle != address(0), "oracle address cannot be 0 address");
        VhostOracle = _VhostOracle;
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
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
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

}