// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVm {
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function warp(uint256 newTimestamp) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function sign(uint256 privateKey, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external pure returns (address);
}

abstract contract BaseTest {
    IVm internal constant vm = IVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error AssertionFailed(string message);

    function assertEq(uint256 a, uint256 b) internal pure {
        if (a != b) revert AssertionFailed("uint256 mismatch");
    }

    function assertEq(address a, address b) internal pure {
        if (a != b) revert AssertionFailed("address mismatch");
    }

    function assertEq(bytes32 a, bytes32 b) internal pure {
        if (a != b) revert AssertionFailed("bytes32 mismatch");
    }

    function assertEq(string memory a, string memory b) internal pure {
        if (keccak256(bytes(a)) != keccak256(bytes(b))) revert AssertionFailed("string mismatch");
    }

    function assertTrue(bool cond) internal pure {
        if (!cond) revert AssertionFailed("expected true");
    }

    function assertFalse(bool cond) internal pure {
        if (cond) revert AssertionFailed("expected false");
    }
}
