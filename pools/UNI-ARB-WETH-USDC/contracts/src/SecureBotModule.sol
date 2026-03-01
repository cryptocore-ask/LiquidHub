// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);
}

contract SecureBotModule {
    address public immutable safe;
    address public immutable botAddress;
    address public immutable rangeManager;
    address public immutable vault;
    address public owner;
    
    // Sécurité renforcée
    mapping(bytes4 => bool) public allowedFunctions;
    uint256 public dailyLimit;
    uint256 public dailySpent;
    uint256 public lastResetDay;
    bool public paused;
    
    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    
    constructor(
        address _safe,
        address _botAddress, 
        address _rangeManager,
        address _vault,
        uint256 _dailyLimit
    ) {
        safe = _safe;
        botAddress = _botAddress;
        rangeManager = _rangeManager;
        vault = _vault;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;
        
        // Autoriser les fonctions essentielles au deploiement
        // Fonctions RangeManager
        allowedFunctions[0x6509c2dd] = true; // configurePriceFeeds(address,address,address)
        allowedFunctions[0x63ccfd0b] = true; // mintInitialPosition
        allowedFunctions[0x38ca63bc] = true; // burnPosition (collecte fees + retire liquidite)
        allowedFunctions[0xb07391c0] = true; // executeSwap (swaps via Uniswap V3)
        allowedFunctions[0xde5aa922] = true; // configureRanges
        allowedFunctions[0x7f9dc7d2] = true; // configureSlippage
        allowedFunctions[0x19218994] = true; // setMaxPositions
        allowedFunctions[0x7d48e49b] = true; // configureProtections(bool,bool,bool,uint16)
        allowedFunctions[0x66231dcd] = true; // configureTolerance

        // Fonctions MultiUserVault
        allowedFunctions[0x99dd7ead] = true; // processPendingDeposits
        allowedFunctions[0xac1df9bd] = true; // processSingleDeposit (traitement individuel)
        allowedFunctions[0x4dce7057] = true; // startRebalance()
        allowedFunctions[0x0040718e] = true; // endRebalance()
        allowedFunctions[0x2a7cf2fe] = true; // addLiquidityToPosition

    }
    
    modifier onlyBot() {
        require(msg.sender == botAddress, "Only bot allowed");
        require(!paused, "Module paused");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
    modifier onlyAllowedFunction(bytes calldata data) {
        require(data.length >= 4, "Invalid data");
        bytes4 selector = bytes4(data[:4]);
        require(allowedFunctions[selector], "Function not allowed");
        _;
    }
    
    modifier withinDailyLimit() {
        uint256 currentDay = block.timestamp / 86400;
        if (currentDay != lastResetDay) {
            dailySpent = 0;
            lastResetDay = currentDay;
        }
        require(dailySpent < dailyLimit, "Daily limit exceeded");
        dailySpent++;
        _;
    }
    
    // Fonction existante pour RangeManager
    function executeRangeManagerFunction(bytes calldata data) 
        external 
        onlyBot 
        onlyAllowedFunction(data) 
        withinDailyLimit 
    {
        bool success = ISafe(safe).execTransactionFromModule(rangeManager, 0, data, 0);
        require(success, "Execution failed");
        
        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }
    
    // Fonctions pour MultiUserVault
    function executeVaultFunction(bytes calldata data) 
        external 
        onlyBot 
        onlyAllowedFunction(data) 
        withinDailyLimit 
    {
        bool success = ISafe(safe).execTransactionFromModule(vault, 0, data, 0);
        require(success, "Execution failed");
        
        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }
    
    // Fonctions d'administration (appelées par la Safe)
    function allowFunction(bytes4 selector, bool allowed) external onlyOwner {
        allowedFunctions[selector] = allowed;
        emit FunctionAllowed(selector, allowed);
    }
    
    function setDailyLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0 && newLimit <= 1000, "Invalid limit");
        dailyLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }
    
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }
    
    // Fonctions de lecture
    function getDailyStats() external view returns (
        uint256 limit,
        uint256 spent, 
        uint256 remaining,
        uint256 resetsIn
    ) {
        uint256 currentDay = block.timestamp / 86400;
        uint256 actualSpent = (currentDay == lastResetDay) ? dailySpent : 0;
        
        return (
            dailyLimit,
            actualSpent,
            dailyLimit - actualSpent,
            86400 - (block.timestamp % 86400)
        );
    }
    
    function isFunctionAllowed(bytes4 selector) external view returns (bool) {
        return allowedFunctions[selector];
    }
}