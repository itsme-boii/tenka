// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal smart-contract wallet: valid signatures are the owner's ECDSA signature.
contract MockERC1271Wallet {
    address public immutable OWNER;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == OWNER, "owner");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && signer == OWNER) return 0x1626ba7e;
        return 0xffffffff;
    }
}
