// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice On the first transfer after `arm`, calls back into `target` with `payload`
///         and records whether the call succeeded.
contract MockReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public succeeded;
    bytes public revertData;

    constructor() ERC20("Reentrant Token", "RE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (target != address(0) && !attempted) {
            attempted = true;
            (bool ok, bytes memory ret) = target.call(payload);
            succeeded = ok;
            revertData = ret;
        }
        super._update(from, to, value);
    }
}
