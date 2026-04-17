pragma solidity ^0.8.26;

interface IRandomnessVerifier {
    struct RandomnessRequest {
        address consumer;
        uint256 chainId;
        uint256 epochId;
        bytes32 randomWord;
        uint256 validUntil;
    }

    function verify(RandomnessRequest calldata request, bytes calldata proof) external view returns (bytes32 digest);
}
