pragma solidity ^0.8.26;

interface Vm {
    function warp(uint256 newTimestamp) external;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
}

address constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant VM = Vm(VM_ADDRESS);

contract TestBase {
    error AssertionFailed();

    function assertEq(uint256 left, uint256 right) internal pure {
        if (left != right) revert AssertionFailed();
    }

    function assertEq(address left, address right) internal pure {
        if (left != right) revert AssertionFailed();
    }

    function assertEq(bytes32 left, bytes32 right) internal pure {
        if (left != right) revert AssertionFailed();
    }

    function assertTrue(bool value) internal pure {
        if (!value) revert AssertionFailed();
    }
}
