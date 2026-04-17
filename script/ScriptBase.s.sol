pragma solidity ^0.8.26;

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function envUint(string calldata name) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
}

address constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant VM = Vm(VM_ADDRESS);

abstract contract Script {
    function run() external virtual;
}
