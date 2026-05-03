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
    address public immutable treasury;
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
        address _treasury,
        uint256 _dailyLimit
    ) {
        safe = _safe;
        botAddress = _botAddress;
        tradingVault = _tradingVault;
        treasury = _treasury;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;

        // Autoriser les fonctions de trading au déploiement
        // openPosition(address,bool,uint256,uint256,uint256,uint256,uint256,uint256,address)
        allowedFunctions[0x3d3a857c] = true;
        // closePosition(bytes32,uint256)
        allowedFunctions[0xdfeba59e] = true;
        // updateStopLoss(bytes32,uint256)
        allowedFunctions[0x73d882f6] = true;
        // updateTakeProfit(bytes32,uint256)
        allowedFunctions[0xf8460c42] = true;
        // cleanCancelledOrder(bytes32)
        allowedFunctions[0xd2dd94af] = true;
        // rescueETH(uint256,address)
        allowedFunctions[0xa0558c3f] = true;
        // authorizeClosure(bytes32,uint8)
        allowedFunctions[0xabc8f1d7] = true;
        // revokeClosureAuthorization(bytes32)
        allowedFunctions[0x38a30ceb] = true;
        // executeStopLoss(bytes32) — fallback après expiration de la fenêtre keeper
        allowedFunctions[0x3a09ccae] = true;
        // executeTakeProfit(bytes32) — fallback après expiration de la fenêtre keeper
        allowedFunctions[0xa240c1b0] = true;

        // Fonctions Treasury (bridge Stargate v2 vers staking contract Phase 2)
        allowedFunctions[0xa5599124] = true; // bridgeToStakers(uint256)
        allowedFunctions[0x1dc28748] = true; // collectAndBridge(address,uint24,uint256,uint256)
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

    /// @notice Execute a function on the TradingVault with ETH (for GMX execution fees)
    /// Le bot envoie l'ETH au module, le module le forward au Vault (receive() payable),
    /// puis appelle la fonction via la Safe sans value.
    /// Le Vault utilise son solde ETH interne pour payer sendWnt à GMX.
    function executeVaultFunctionWithValue(bytes calldata data, uint256 value)
        external
        payable
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        require(msg.value >= value, "Insufficient ETH sent");

        // Forward l'ETH directement au Vault (receive() payable)
        (bool sent,) = tradingVault.call{value: value}("");
        require(sent, "ETH transfer to Vault failed");

        // Appeler via Safe sans value — le Vault a déjà l'ETH pour GMX
        bool success = ISafe(safe).execTransactionFromModule(tradingVault, 0, data, 0);
        require(success, "Execution failed");

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function (bridge operations only, per whitelist)
    function executeTreasuryFunction(bytes calldata data)
        external
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        bool success = ISafe(safe).execTransactionFromModule(treasury, 0, data, 0);
        require(success, "Execution failed");

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function with native ETH value (Stargate cross-chain fees)
    /// @dev The bot forwards ETH with msg.value; the module funds the Safe then calls Treasury.
    function executeTreasuryFunctionWithValue(bytes calldata data, uint256 value)
        external
        payable
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        require(msg.value >= value, "Insufficient ETH sent");

        // Forward ETH to Safe so it can fund the Treasury call
        (bool sent,) = safe.call{value: value}("");
        require(sent, "ETH transfer to Safe failed");

        bool success = ISafe(safe).execTransactionFromModule(treasury, value, data, 0);
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
