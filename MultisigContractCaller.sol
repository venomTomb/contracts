// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
contract multisigContractCaller is Initializable{
    
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    event CancelTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature,  bytes data);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature,  bytes data);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature, bytes data);

    address public multisigCaller1;
    address public multisigCaller2;

    mapping (bytes32 => bool) public queuedTransactions;

    // using openzepplin modifier
    
    function initialize(address _multisigCaller1,address _multisigCaller2) public initializer {
        multisigCaller1 = _multisigCaller1;
        multisigCaller2 = _multisigCaller2;
   
    }

    receive() external payable { }

    function createTransaction(address target, uint value, string memory signature, bytes memory data) public returns (bytes32) {
        require(msg.sender == multisigCaller1, "MultisigContractCaller:: createTransaction: Call must come from multisigCaller1.");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data);
        return txHash;
    }

    function cancelTransaction(address target, uint value, string memory signature, bytes memory data) public {
        require(msg.sender == multisigCaller1  || msg.sender == multisigCaller2 , "MultisigContractCaller:: cancelTransaction: Call must come from MultisigContractCaller.");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data);
    }

    function confirmTransaction(address target, uint value, string memory signature, bytes memory data) public payable returns (bytes memory) {
        require(msg.sender == multisigCaller2, "MultisigContractCaller:: confirmTransaction: Call must come from MultisigContractCaller.");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data));
        require(queuedTransactions[txHash], "MultisigContractCaller:: confirmTransaction: Transaction hasn't been queued.");
        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "MultisigContractCaller:: confirmTransaction: Transaction execution reverted.");

        emit ExecuteTransaction(txHash, target, value, signature, data);

        return returnData;
    }
}