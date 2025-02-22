// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IAIOracle.sol";
import "./AIOracleCallbackReceiver.sol";

contract NFTFactory {
    address[] public deployedNFTs;

    event NFTContractCreated(address indexed nftContract, string name, string symbol, address creator);

    function createNFT(string memory name, string memory symbol, string memory _prompt, uint256 _price) public {
        MantleMistrery newNFT = new MantleMistrery(IAIOracle(0x0A0f4321214BB6C7811dD8a71cF587bdaF03f0A0),name, symbol, _prompt, _price, msg.sender);
        deployedNFTs.push(address(newNFT));
        emit NFTContractCreated(address(newNFT), name, symbol, msg.sender);
    }

    function getDeployedNFTs() public view returns (address[] memory) {
        return deployedNFTs;
    }
}

contract MantleMistrery is AIOracleCallbackReceiver, ERC721URIStorage, Ownable  {
    event promptsUpdated(
        uint256 requestId,
        uint256 modelId,
        string input,
        string output,
        bytes callbackData
    );

    event NFTMinted(
        address recipient,
        uint256 tokenId,
        uint8 rarity
    );

    event promptRequest(
        uint256 requestId,
        address sender,
        uint256 modelId,
        string prompt
    );

    struct AIOracleRequest {
        address sender;
        uint256 modelId;
        bytes input;
        bytes output;
    }

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
    string public prompt;
    // tokenID => Rarity
    mapping(uint256 => uint8) public rarity;
    uint256 public price;

    mapping(uint256 => mapping(string => string)) public prompts;

    // requestId => AIOracleRequest
    mapping(uint256 => AIOracleRequest) public requests;

    // modelId => callback gasLimit
    mapping(uint256 => uint64) public callbackGasLimit;

    mapping(uint256 => uint256) public requestIdToTokenId;

    /// @notice Initialize the contract, binding it to a specified AIOracle.
    constructor(IAIOracle _aiOracle, string memory _tokenName, string memory _tokenSymbol , string memory _prompt, uint256 _price , address _creator) ERC721(_tokenName, _tokenSymbol) AIOracleCallbackReceiver(_aiOracle) {
        prompt = _prompt;
        price = _price;
        transferOwnership(_creator);
    }

    function setCallbackGasLimit(uint256 modelId, uint64 gasLimit) external onlyOwner {
        callbackGasLimit[modelId] = gasLimit;
    }

    function randomRarity() internal view returns (uint8) {
        uint256 randomHash = uint256(keccak256(abi.encodePacked(block.number, block.timestamp, msg.sender)));
        uint8 _rarity = uint8(randomHash % 100) + 1;

        return _rarity;
    }

    function getAIResult(uint256 modelId, string calldata _prompt) external view returns (string memory) {
        return prompts[modelId][_prompt];
    }

    // the callback function, only the AI Oracle can call this function
    function aiOracleCallback(uint256 requestId, bytes calldata output, bytes calldata callbackData) external override onlyAIOracleCallback() {
        // since we do not set the callbackData in this example, the callbackData should be empty
        AIOracleRequest storage request = requests[requestId];
        require(request.sender != address(0), "request not exists");
        request.output = output;
        prompts[request.modelId][string(request.input)] = string(output);
        _setTokenURI(requestIdToTokenId[requestId], string(output));
        emit promptsUpdated(requestId, request.modelId, string(request.input), string(output), callbackData);
    }

    function estimateFee(uint256 modelId) public view returns (uint256) {
        return aiOracle.estimateFee(modelId, callbackGasLimit[modelId]);
    }

    function mintNFT(address recipient, uint256 modelId) payable external  {
        require(msg.value > price, "Incorrect ETH value sent");
        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();
        rarity[newItemId] = randomRarity();

        _mint(recipient, newItemId);
        bytes memory input = bytes(prompt);
        // we do not need to set the callbackData in this example
        uint256 requestId = aiOracle.requestCallback{value: msg.value - price}(
            modelId, input, address(this), callbackGasLimit[modelId], ""
        );

        AIOracleRequest storage request = requests[requestId];
        request.input = input;
        request.sender = msg.sender;
        request.modelId = modelId;
        requestIdToTokenId[requestId] = newItemId;
        emit promptRequest(requestId, msg.sender, modelId, prompt);
        emit NFTMinted(recipient, newItemId, rarity[newItemId]);
    }

    function withdraw() external onlyOwner {
        require(address(this).balance > 0, "No ETH to withdraw");
        // transfer profit to owner
        payable(owner()).transfer(address(this).balance);
    }
}
