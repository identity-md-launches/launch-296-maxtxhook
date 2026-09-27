// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

library HookMiner {
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function find(address deployer, bytes32 initCodeHash)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted = predict(deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.MAX_TX)) return (salt, predicted);
        }
        revert("CREATE2 salt search exhausted");
    }
}
