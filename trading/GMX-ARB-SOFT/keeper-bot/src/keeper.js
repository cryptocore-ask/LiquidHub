/**
 * GMX Trading Keeper Bot
 *
 * Monitors TradingVault positions using Chainlink on-chain price feeds and executes:
 *   - executeStopLoss(key) when price hits SL (adjusted for leverage)
 *   - executeTakeProfit(key) when price hits TP (adjusted for leverage)
 *   - liquidatePosition(key) when collateral < maintenance margin
 *   - settleAll() to collect protocol commissions on profitable closed trades
 *
 * SL/TP percentages are on collateral (not price), divided by leverage.
 * Example: SL=4% with 2x leverage → triggers at 2% price movement.
 *
 * Earns USDC bounty from Treasury when keeperBountyEnabled is true.
 */

require('dotenv').config();
const { ethers } = require('ethers');

// ===== ABIs =====

const TRADING_VAULT_ABI = [
    'function getActivePositionCount() view returns (uint256)',
    'function activePositionKeys(uint256 index) view returns (bytes32)',
    'function positions(bytes32 key) view returns (address market, bool isLong, uint256 collateralAmount, uint256 sizeInUsd, uint256 entryPrice, uint256 stopLossPrice, uint256 takeProfitPrice, uint256 openTimestamp, bool isOpen)',
    'function keeperBountyEnabled() view returns (bool)',
    'function gmxReader() view returns (address)',
    'function gmxDataStore() view returns (address)',
    'function executeStopLoss(bytes32 key) external payable',
    'function executeTakeProfit(bytes32 key) external payable',
    'function liquidatePosition(bytes32 key) external payable',
    'function settleAll() external',
    'function pendingSettlements(uint256) view returns (bytes32 positionKey, uint256 collateralAmount, uint256 entryPrice8dec, bool isLong, uint256 timestamp, bool settled)',
    'function closureAuthorizations(bytes32 key) view returns (uint64 authorizedAt, uint64 expiresAt, uint8 closureType)',
    'function isClosureAuthorized(bytes32 key, uint8 closureType) view returns (bool)',
    'event ClosureAuthorized(bytes32 indexed key, uint8 closureType, uint64 expiresAt)',
];

const GMX_READER_ABI = [
    'function getPosition(address dataStore, bytes32 key) view returns (tuple(tuple(address account, address market, address collateralToken) addresses, tuple(uint256 sizeInUsd, uint256 sizeInTokens, uint256 collateralAmount, uint256 borrowingFactor, uint256 fundingFeeAmountPerSize, uint256 longTokenClaimableFundingAmountPerSize, uint256 shortTokenClaimableFundingAmountPerSize, uint256 increasedAtBlock, uint256 increasedAtTime) numbers, tuple(bool isLong, bool shouldUnwrapNativeToken) flags))',
    'function getMarket(address dataStore, address marketAddress) view returns (tuple(address marketToken, address indexToken, address longToken, address shortToken))',
];

const CHAINLINK_ABI = [
    'function latestAnswer() view returns (int256)',
    'function decimals() view returns (uint8)',
];

// ===== Chainlink Price Feeds on Arbitrum =====
// Only tokens with verified feeds (deviation ≤ 1%) are supported.

const CHAINLINK_FEEDS = {
    'ETH':'0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612','BTC':'0xd0C7101eACbB49F3deCcCc166d238410D6D46d57',
    'LINK':'0x86E53CF1B870786351Da77A57575e79CB55812CB','ARB':'0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6',
    'UNI':'0x9C917083fDb403ab5ADbEC26Ee294f6EcAda2720','GMX':'0xDB98056FecFff59D032aB628337A4887110df3dB',
    'AAVE':'0xaD1d5344AaDE45F43E596773Bcc4c423EAbdD034','PENDLE':'0x66853E19d73c0F9301fe099c324A1E9726953433',
    'CRV':'0xaebDA2c976cfd1eE1977Eac079B4382acb849325','CVX':'0x851175a919f36c8e30197c09a9A49dA932c2CC00',
    'LDO':'0xA43A34030088E6510FecCFb77E88ee5e7ed0fE64','SOL':'0x24ceA4b8ce57cdA5058b924B9B9987992450590c',
    'NEAR':'0xBF5C3fB2633e924598A46B9D07a174a9DBcF57C0','ATOM':'0xCDA67618e51762235eacA373894F0C79256768fa',
    'AVAX':'0x8bf61728eeDCE2F32c456454d87B5d6eD6150208','OP':'0x205aaD468a11fd5D34fA7211bC6Bad5b3deB9b98',
    'BNB':'0x6970460aabF80C5BE983C6b74e5D06dEDCA95D4A','XRP':'0xB4AD57B52aB9141de9926a3e0C8dc6264c2ef205',
    'LTC':'0x5698690a7B7B84F6aa985ef7690A8A7288FBc9c8','ADA':'0xD9f615A9b820225edbA2d821c4A696a0924051c6',
    'DOT':'0xa6bC5bAF2000424e90434bA7104ee399dEe80DEc','SEI':'0xCc9742d77622eE9abBF1Df03530594f9097bDcB3',
    'TON':'0x0301e5D0A8f7490444ebd1921E3d0f0fe7722786','SUI':'0x4a85B128EBDaFC24d5CB611e161376ffDECeB289',
    'TIA':'0x4096b9bfB4c34497B7a3939D4f629cf65EBf5634','POL':'0x82BA56a2fADF9C14f17D08bc51bDA0bDB83A8934',
    'STX':'0x3a9659C071dD3C37a8b1A2363409A8D41B2Feae3','APT':'0xdc49F292ad1bb3DAb6C11363d74ED06F38b9bd9C',
    'DOGE':'0x9A7FB1b3950837a8D9b40517626E11D4127C098C','PEPE':'0x02DEd5a7EDDA750E3Eb240b54437a54d57b74dBE',
    'SHIB':'0x0E278D14B4bf6429dDB0a1B353e2Ae8A4e128C93','WIF':'0xF7Ee427318d2Bd0EEd3c63382D0d52Ad8A68f90D',
    'ORDI':'0x76998C22eEa325A11dc6971Cedcf533E9740F854','TRUMP':'0x373510BDa1ab7e873c731968f4D81B685f520E4B',
    'MELANIA':'0xE2CB592D636c500a6e469628054F09d58e4d91BB','ENA':'0x9eE96caa9972c801058CAA8E23419fc6516FbF7e',
    'CAKE':'0x256654437f1ADA8057684b18d742eFD14034C400','HYPE':'0xf9ce4fE2F0EcE0362cb416844AE179a49591D567',
    'ZRO':'0x1940fEd49cDBC397941f2D336eb4994D599e568B','APE':'0x221912ce795669f628c51c69b7d0873eDA9C03bB',
    'BERA':'0x4f861F14246229530a881D32C8d26D78b8c48BE6','XPL':'0x1b47b4124b9A5094C59710E6b9126e5e32a4fb8E',
    '0G':'0x47C38C695639aE97A00f57D6D9f5ece1DebB033C','MON':'0x0225781042C46dB247e009FFEAd5aEf044f3E7BE',
    'ZEC':'0x21082CA28570f0ccfb089465bFaEfDc77b00D367','DOLO':'0x17d8D87dF3E279c737568aB0C5cC3fF750aB763e',
    'WLFI':'0x4b13Dd76De990Db9A2Dab58D35C2c02E5e3AE848','PUMP':'0x0C997958ccE7A0403AEA7E34d14bbaDA897B5bb3',
};

// Index token address → symbol (for resolving GMX market to Chainlink feed)
// Covers all GMX v2 Arbitrum index tokens (native + synthetic addresses).
const GMX_TOKEN_MAP = {
    // Majors
    '0x82af49447d8a07e3bd95bd0d56f35241523fbab1': 'ETH',
    '0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f': 'BTC',
    '0x912ce59144191c1204e64559fe8253a0e49e6548': 'ARB',
    '0xf97f4df75117a78c1a5a0dbb814af92458539fb4': 'LINK',
    '0xfa7f8980b0f1e64a2062791cc3b0871572f1f7f0': 'UNI',
    '0xfc5a1a6eb076a2c7ad06ed22c90d7e710e35ad0a': 'GMX',
    // DeFi / L1 / L2
    '0xba5ddd1f9d7f570dc94a51479a000e3bce967196': 'AAVE',
    '0x0c880f6761f1af8d9aa9c466984b80dab9a8c9e8': 'PENDLE',
    '0x9d678b4dd38a6e01df8090aeb7974ad71142b05f': 'LDO',
    '0xe5f01aeacc8288e9838a60016ab00d7b6675900b': 'CRV',
    '0x3b6f801c0052dfe0ac80287d611f31b7c47b9a6b': 'CVX',
    // Alt L1/L2
    '0x2bcca44f67dc679d8a2ec39c1d50c6b7a1b50f00': 'SOL',
    '0xb2f82d0f38dc453d596ad40a37799446c35454f3': 'SOL',
    '0x2bcc6d6cdbbdc0a4071e48bb3b969b06b3330c07': 'SOL',
    '0xaaa6c1e32c55a7bfa8066a6fae9b42650f262418': 'NEAR',
    '0x13ad51ed4f1b7e9dc0b7014d7ecf3287b45d5046': 'NEAR',
    '0x1ff7f3efbb9481cbd7db4f932cbcd4467144237c': 'NEAR',
    '0x7f56a74b7f4dc72e40e49a5f2bb20cdaa2e66cf3': 'ATOM',
    '0x7d7f1765acbaf847b9a1f7137fe8ed4931fbfeba': 'ATOM',
    '0x3e6648c5a70a150a88bce65f4ad4d506fe15d2af': 'AVAX',
    '0x565609faf65b92f7be02468acf86f8979423e514': 'AVAX',
    '0x7c7ab5f20a5c2e38da0fefe0e62802789e0cc5c1': 'OP',
    '0xac800fd6159c2a2cb8fc31ef74621eb430287a5a': 'OP',
    '0x47904963fc8b2340414262125af798b9655e58cd': 'BNB',
    '0xa9004a5421372e1d83fb1f85b0fc986c912f91f3': 'BNB',
    '0xc14e065b0067de91534e032868f5ac6ecf2c6868': 'XRP',
    '0x02b3e4dd0a413e9ae1b6e491e6a1f28f52b09c00': 'LTC',
    '0xe958f107b467d5172573f761d26931d658c1b436': 'DOT',
    '0x55e85a147a1029b985384822c0b2262df8023452': 'SEI',
    '0xb2f7cefaeeb08aa347705ac829a7b8be2fb560f3': 'TON',
    '0x1ff7f3efc1f41efba0d1c89d2568cc907307adb4': 'SUI',
    '0x197aa2de1313c7ad50184234490e12409b2a1f95': 'SUI',
    '0x09199d9a5f4ded29a7ce0a17e49981a60d936b03': 'TIA',
    '0x38676f62d166f5ce7de8433f51c6b3d6d9d66c19': 'TIA',
    '0x9c74772b713a1b032aeb173e28683d937e51921c': 'POL',
    '0xbaf07cf91d413c0acb2b7444b9bf13b4e03c9d71': 'STX',
    '0x3f8f0dce4dce4d0d1d0871941e79cda82ca50d0b': 'APT',
    // Meme
    '0x25d887ce7a35172c62febfd67a1856f20faebb00': 'PEPE',
    '0x7dd9c5cba05e151c895fde1cf355c9a1d5da6429': 'PEPE',
    '0x35751007a407ca6feffe80b3cb397736d2cf4dbe': 'DOGE',
    '0xc4da4c24fd591125c3f47b340b6f4f76111883d8': 'DOGE',
    '0x580e933d90091b9ce380740e3a4a39c67eb85b4c': 'SHIB',
    '0x3e57d02f9d196873e55727382974b02edebe6bfd': 'SHIB',
    '0xb46a094bc4b0adbd801e14b9db95e05e28962764': 'WIF',
    '0xa1b91fe9fd52141ff8cac388ce3f10bfdc1de79d': 'WIF',
    '0x565609fa65662a28604f2f90a4d0e1d682c0103a': 'ORDI',
    '0x1e15d08f3ca46853b692ee28ae9c7a0b88a9c994': 'ORDI',
    '0x30021afa4767ad66aa52a06df8a5ab3aca9371fd': 'TRUMP',
    '0xfa4f8e582214ebce1a08eb2a65e08082053e441f': 'MELANIA',
    // DeFi v2 / New
    '0xfe1aac2cd9c5cc77b58eecfe75981866ed0c8b7a': 'ENA',
    '0x580b373ac16803bb0133356f470f3c7eef54151b': 'CAKE',
    '0xfdfa0a749da3bccee20ae0b4ad50e39b26f58f7c': 'HYPE',
    '0xa8193c55c34ed22e1dbe73fd5adc668e51578a67': 'ZRO',
    '0x7f9fbf9bdd3f4105c478b996b648fe6e828a1e98': 'APE',
    '0x67adabbad211ea9b3b4e2fd0fd165e593de1e983': 'BERA',
    // Additional
    '0x2e73bdbee83d91623736d514b0bb41f2afd9c7fd': 'XPL',
    '0x95c317066cf214b2e6588b2685d949384504f51e': '0G',
    '0xb96e60ca3a7677b29f1e10dd109e952b275038be': 'MON',
    '0x6eabbaa3278556dc5b19c034dc26c0eab60d65b5': 'ZEC',
    '0x97ce1f309b949f7fbc4f58c5cb6aa417a5ff8964': 'DOLO',
    '0xc5799ab6e2818fd8d0788db8d156b0c5db1bf97b': 'WLFI',
    '0x9c060b2fa953b5f69879a8b7b81f62bffef360be': 'PUMP',
};

// ===== Config =====

const CHECK_INTERVAL = parseInt(process.env.CHECK_INTERVAL_MS || '30000');
const EXECUTION_FEE = ethers.parseEther(process.env.EXECUTION_FEE || '0.0002');
const SL_PERCENT = parseFloat(process.env.DEFAULT_STOP_LOSS_PERCENT || '4');
const TP_PERCENT = parseFloat(process.env.DEFAULT_TAKE_PROFIT_PERCENT || '8');
const SETTLE_INTERVAL = 5 * 60 * 1000;
let lastSettleTime = 0;

// Ultimate Short Stop Loss — safety cap when SHORT position loses >X% (bypass any other logic).
// Disabled by default. Enable via ULTIM_SHORT_STOP_LOSS_ENABLED=true, threshold via ULTIM_SHORT_STOP_LOSS_PERCENT.
const ULTIM_SHORT_SL_ENABLED = (process.env.ULTIM_SHORT_STOP_LOSS_ENABLED || 'false') === 'true';
const ULTIM_SHORT_SL_PERCENT = parseFloat(process.env.ULTIM_SHORT_STOP_LOSS_PERCENT || '20');

// Symbol cache per market address
const marketSymbolCache = {};

// ===== Helper: RPC fallback =====
//
// Build providers list from RPC_URL + RPC_BACKUP_1 + RPC_BACKUP_2.
// callWithRpcFallback executes `fn` on each provider in order until success.
// Throws if all RPCs fail — caller should skip the cycle to avoid acting on incomplete state.

function buildProviders() {
    const urls = [process.env.RPC_URL, process.env.RPC_BACKUP_1, process.env.RPC_BACKUP_2].filter(Boolean);
    return urls.map(url => new ethers.JsonRpcProvider(url));
}

async function callWithRpcFallback(providers, fn, label = 'RPC call') {
    let lastError;
    for (let i = 0; i < providers.length; i++) {
        try {
            return await fn(providers[i]);
        } catch (e) {
            lastError = e;
            if (i < providers.length - 1) {
                console.warn(`${label}: RPC ${i === 0 ? 'primary' : `backup ${i}`} failed (${(e.message || '').slice(0, 80)}), trying next`);
            }
        }
    }
    throw new Error(`${label}: all ${providers.length} RPCs failed — last error: ${lastError && lastError.message}`);
}

// ===== Helper: resolve market to symbol =====

async function resolveMarketSymbol(reader, dataStore, marketAddress, providers) {
    const key = marketAddress.toLowerCase();
    if (marketSymbolCache[key]) return marketSymbolCache[key];

    try {
        const market = await callWithRpcFallback(providers, async (provider) => {
            const r = new ethers.Contract(reader.target, GMX_READER_ABI, provider);
            return await r.getMarket(dataStore, marketAddress);
        }, 'resolveMarketSymbol');
        const symbol = GMX_TOKEN_MAP[market.indexToken.toLowerCase()] || null;
        if (symbol) marketSymbolCache[key] = symbol;
        return symbol;
    } catch {
        return null;
    }
}

// ===== Helper: get Chainlink price in USD =====

async function getChainlinkPrice(symbol, providers) {
    const feedAddr = CHAINLINK_FEEDS[symbol];
    if (!feedAddr) return null;

    try {
        return await callWithRpcFallback(providers, async (provider) => {
            const feed = new ethers.Contract(feedAddr, CHAINLINK_ABI, provider);
            const [answer, dec] = await Promise.all([feed.latestAnswer(), feed.decimals()]);
            return Number(answer) / Math.pow(10, Number(dec));
        }, `getChainlinkPrice ${symbol}`);
    } catch {
        return null;
    }
}

// ===== Main =====

async function main() {
    const providers = buildProviders();
    if (providers.length === 0) {
        console.error('No RPC URLs configured (RPC_URL / RPC_BACKUP_1 / RPC_BACKUP_2)');
        process.exit(1);
    }
    const wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, providers[0]);
    const vault = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, wallet);

    console.log(`Keeper bot started`);
    console.log(`  Vault: ${process.env.TRADING_VAULT_ADDRESS}`);
    console.log(`  Keeper: ${wallet.address}`);
    console.log(`  RPCs: ${providers.length} configured (primary + ${providers.length - 1} backup)`);
    console.log(`  Interval: ${CHECK_INTERVAL}ms`);
    console.log(`  SL: ${SL_PERCENT}% | TP: ${TP_PERCENT}% (on collateral, adjusted for leverage)`);
    console.log(`  Prices: Chainlink on-chain`);

    // bounty flag is read once at startup — non-critical if it fails, default to false
    let bountyEnabled = false;
    try {
        bountyEnabled = await callWithRpcFallback(providers, async (provider) => {
            const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
            return await v.keeperBountyEnabled();
        }, 'keeperBountyEnabled');
    } catch (e) {
        console.warn(`Could not read bounty status: ${e.message?.slice(0, 80)}`);
    }
    console.log(`  Bounty: ${bountyEnabled ? 'ENABLED' : 'disabled'}`);

    while (true) {
        try {
            // Read vault state with RPC fallback. If all RPCs fail, skip this cycle entirely.
            let count, readerAddr, dataStoreAddr;
            try {
                const state = await callWithRpcFallback(providers, async (provider) => {
                    const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                    const [c, r, d] = await Promise.all([
                        v.getActivePositionCount(),
                        v.gmxReader(),
                        v.gmxDataStore(),
                    ]);
                    return { count: c, readerAddr: r, dataStoreAddr: d };
                }, 'vault state');
                count = state.count;
                readerAddr = state.readerAddr;
                dataStoreAddr = state.dataStoreAddr;
            } catch (e) {
                console.error(`All RPCs failed reading vault state — skipping cycle: ${e.message?.slice(0, 100)}`);
                await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL));
                continue;
            }

            if (count > 0n) {
                // Build a reader instance for the helper functions (provider doesn't matter — they use providers[] anyway)
                const reader = new ethers.Contract(readerAddr, GMX_READER_ABI, providers[0]);

                for (let i = 0; i < Number(count); i++) {
                    let key;
                    try {
                        key = await callWithRpcFallback(providers, async (provider) => {
                            const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                            return await v.activePositionKeys(i);
                        }, `activePositionKeys[${i}]`);
                    } catch { continue; }

                    let pos;
                    try {
                        pos = await callWithRpcFallback(providers, async (provider) => {
                            const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                            return await v.positions(key);
                        }, `positions[${key.slice(0, 10)}]`);
                    } catch { continue; }
                    if (!pos.isOpen) continue;

                    // Check if position exists on GMX
                    let gmxPos;
                    try {
                        gmxPos = await callWithRpcFallback(providers, async (provider) => {
                            const r = new ethers.Contract(readerAddr, GMX_READER_ABI, provider);
                            return await r.getPosition(dataStoreAddr, key);
                        }, `getPosition[${key.slice(0, 10)}]`);
                    } catch { continue; }
                    if (gmxPos.numbers.sizeInUsd === 0n && gmxPos.numbers.collateralAmount === 0n) continue;

                    // Resolve symbol via market
                    const symbol = await resolveMarketSymbol(reader, dataStoreAddr, pos.market, providers);
                    if (!symbol) continue;

                    // Get current price from Chainlink (in dollars)
                    const currentPrice = await getChainlinkPrice(symbol, providers);
                    if (!currentPrice) continue;

                    // SL/TP are stored in Chainlink 8-decimal format in the vault
                    // Convert to dollars for comparison
                    const slPrice8dec = Number(pos.stopLossPrice);
                    const tpPrice8dec = Number(pos.takeProfitPrice);
                    const slDollar = slPrice8dec / 1e8;
                    const tpDollar = tpPrice8dec / 1e8;

                    // Entry price in dollars (from Chainlink 8-decimal format)
                    const entryDollar = Number(pos.entryPrice) / 1e8;

                    // Ultimate Short Stop Loss — absolute safety cap for SHORT positions.
                    // Still gated by the vault's closure authorization (the bot decides).
                    if (!pos.isLong && ULTIM_SHORT_SL_ENABLED && entryDollar > 0) {
                        const ultimSlPrice = entryDollar * (100 + ULTIM_SHORT_SL_PERCENT) / 100;
                        if (currentPrice >= ultimSlPrice) {
                            let authorized;
                            try {
                                authorized = await callWithRpcFallback(providers, async (provider) => {
                                    const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                                    return await v.isClosureAuthorized(key, 1);
                                }, `isClosureAuthorized[ULTIM ${symbol}]`);
                            } catch { continue; }
                            if (!authorized) continue;
                            const loss = ((currentPrice - entryDollar) / entryDollar * 100).toFixed(1);
                            console.log(`ULTIM SHORT SL ${symbol}: $${currentPrice.toFixed(6)} >= $${ultimSlPrice.toFixed(6)} (+${loss}% vs entry) — authorized, executing`);
                            try {
                                const tx = await vault.executeStopLoss(key, { value: EXECUTION_FEE, gasLimit: 2_000_000 });
                                const receipt = await tx.wait();
                                console.log(`  Ultim SL executed: ${receipt.hash}`);
                            } catch (e) {
                                console.error(`  Ultim SL execution failed: ${e.message?.slice(0, 80)}`);
                            }
                            continue;
                        }
                    }

                    // Check Stop Loss — ONLY execute if the bot has authorized closure.
                    // The vault protocol requires the bot to call authorizeClosure(key, 1) first,
                    // which gives community keepers a ~2min window to execute (and earn bounty).
                    if (slDollar > 0) {
                        const slTriggered = pos.isLong
                            ? currentPrice <= slDollar
                            : currentPrice >= slDollar;

                        if (slTriggered) {
                            let authorized;
                            try {
                                authorized = await callWithRpcFallback(providers, async (provider) => {
                                    const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                                    return await v.isClosureAuthorized(key, 1);
                                }, `isClosureAuthorized[SL ${symbol}]`);
                            } catch { continue; }
                            if (!authorized) {
                                // SL condition met but bot has not authorized — bot's internal logic
                                // (e.g. Grok confirmation) is holding the position. Skip.
                                continue;
                            }
                            console.log(`SL triggered ${symbol} ${pos.isLong ? 'LONG' : 'SHORT'}: $${currentPrice.toFixed(6)} vs sl=$${slDollar.toFixed(6)} — authorized, executing`);
                            try {
                                const tx = await vault.executeStopLoss(key, { value: EXECUTION_FEE, gasLimit: 2_000_000 });
                                const receipt = await tx.wait();
                                console.log(`  SL executed: ${receipt.hash}`);
                            } catch (e) {
                                console.error(`  SL execution failed: ${e.message?.slice(0, 80)}`);
                            }
                            continue;
                        }
                    }

                    // Check Take Profit — same authorization logic as SL
                    if (tpDollar > 0) {
                        const tpTriggered = pos.isLong
                            ? currentPrice >= tpDollar
                            : currentPrice <= tpDollar;

                        if (tpTriggered) {
                            let authorized;
                            try {
                                authorized = await callWithRpcFallback(providers, async (provider) => {
                                    const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                                    return await v.isClosureAuthorized(key, 2);
                                }, `isClosureAuthorized[TP ${symbol}]`);
                            } catch { continue; }
                            if (!authorized) {
                                continue;
                            }
                            console.log(`TP triggered ${symbol} ${pos.isLong ? 'LONG' : 'SHORT'}: $${currentPrice.toFixed(6)} vs tp=$${tpDollar.toFixed(6)} — authorized, executing`);
                            try {
                                const tx = await vault.executeTakeProfit(key, { value: EXECUTION_FEE, gasLimit: 2_000_000 });
                                const receipt = await tx.wait();
                                console.log(`  TP executed: ${receipt.hash}`);
                            } catch (e) {
                                console.error(`  TP execution failed: ${e.message?.slice(0, 80)}`);
                            }
                            continue;
                        }
                    }

                    // Check Liquidation
                    const collateral30 = gmxPos.numbers.collateralAmount * BigInt(1e24);
                    const maintenanceMargin = gmxPos.numbers.sizeInUsd / 100n;
                    if (collateral30 <= maintenanceMargin) {
                        console.log(`Liquidation ${symbol}: collateral below maintenance margin`);
                        try {
                            const tx = await vault.liquidatePosition(key, { value: EXECUTION_FEE, gasLimit: 2_000_000 });
                            const receipt = await tx.wait();
                            console.log(`  Liquidated: ${receipt.hash}`);
                        } catch (e) {
                            console.error(`  Liquidation failed: ${e.message?.slice(0, 80)}`);
                        }
                    }
                }
            }

            // Settle pending commissions every 5 minutes
            if (Date.now() - lastSettleTime > SETTLE_INTERVAL) {
                lastSettleTime = Date.now();
                try {
                    let hasPending = false;
                    for (let i = 0; i < 20; i++) {
                        try {
                            const s = await callWithRpcFallback(providers, async (provider) => {
                                const v = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, provider);
                                return await v.pendingSettlements(i);
                            }, `pendingSettlements[${i}]`);
                            if (!s.settled) { hasPending = true; break; }
                        } catch { break; }
                    }
                    if (hasPending) {
                        const tx = await vault.settleAll({ gasLimit: 500000 });
                        const receipt = await tx.wait();
                        console.log(`Commissions settled: ${receipt.hash}`);
                    }
                } catch (e) {
                    if (!e.message?.includes('require(false)')) {
                        console.error(`Settle error: ${e.message?.slice(0, 60)}`);
                    }
                }
            }
        } catch (e) {
            console.error(`Check cycle error: ${e.message}`);
        }

        await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL));
    }
}

main().catch(err => {
    console.error('Keeper bot crash:', err);
    process.exit(1);
});
