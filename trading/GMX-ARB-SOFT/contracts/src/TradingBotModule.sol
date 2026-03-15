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

contract TradingBotModule {
    address public immutable safe;
    address public immutable botAddress;
    address public immutable tradingVault;
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
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(
        address _safe,
        address _botAddress,
        address _tradingVault,
        uint256 _dailyLimit
    ) {
        safe = _safe;
        botAddress = _botAddress;
        tradingVault = _tradingVault;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;

        // Autoriser les fonctions de trading au déploiement
        // openPosition(address,bool,uint256,uint256,uint256,uint256,uint256,uint256)
        allowedFunctions[0x6dc3a44e] = true;
        // closePosition(bytes32)
        allowedFunctions[0xe54a2ad5] = true;
        // updateStopLoss(bytes32,uint256)
        allowedFunctions[0x73d882f6] = true;
        // updateTakeProfit(bytes32,uint256)
        allowedFunctions[0xf8460c42] = true;
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

    /// @notice Execute a function on the TradingVault via the Safe
    function executeVaultFunction(bytes calldata data)
        external
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        bool success = ISafe(safe).execTransactionFromModule(tradingVault, 0, data, 0);
        require(success, "Execution failed");

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a function on the TradingVault with ETH value (for execution fees)
    function executeVaultFunctionWithValue(bytes calldata data, uint256 value)
        external
        payable
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        bool success = ISafe(safe).execTransactionFromModule(tradingVault, value, data, 0);
        require(success, "Execution failed");

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    // --- Administration (appelées par la Safe) ---

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

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- Lecture ---

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
