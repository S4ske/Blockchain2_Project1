pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IRandomnessVerifier} from "./interfaces/IRandomnessVerifier.sol";

contract SignatureRandomnessVerifier is IRandomnessVerifier, Ownable {
    error ZeroAddress();
    error RandomnessExpired(uint256 validUntil, uint256 currentTime);
    error InvalidSigner(address signer);

    using MessageHashUtils for bytes32;

    bytes32 public constant TYPEHASH = keccak256(
        "RandomnessRequest(address consumer,uint256 chainId,uint256 epochId,bytes32 randomWord,uint256 validUntil)"
    );

    mapping(address => bool) public trustedSigners;

    event TrustedSignerUpdated(address indexed signer, bool allowed);

    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) {
        if (initialSigner == address(0)) revert ZeroAddress();
        trustedSigners[initialSigner] = true;
        emit TrustedSignerUpdated(initialSigner, true);
    }

    function setTrustedSigner(address signer, bool allowed) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        trustedSigners[signer] = allowed;
        emit TrustedSignerUpdated(signer, allowed);
    }

    function verify(RandomnessRequest calldata request, bytes calldata proof) external view returns (bytes32 digest) {
        if (request.validUntil < block.timestamp) {
            revert RandomnessExpired(request.validUntil, block.timestamp);
        }
        bytes32 structHash = _hashRequest(request);
        digest = structHash.toEthSignedMessageHash();
        address signer = ECDSA.recover(digest, proof);
        if (!trustedSigners[signer]) revert InvalidSigner(signer);
    }

    function _hashRequest(RandomnessRequest calldata request) internal pure returns (bytes32 structHash) {
        bytes32 typeHash = TYPEHASH;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), calldataload(request))
            mstore(add(ptr, 0x40), calldataload(add(request, 0x20)))
            mstore(add(ptr, 0x60), calldataload(add(request, 0x40)))
            mstore(add(ptr, 0x80), calldataload(add(request, 0x60)))
            mstore(add(ptr, 0xa0), calldataload(add(request, 0x80)))
            structHash := keccak256(ptr, 0xc0)
        }
    }
}
