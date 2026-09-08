'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ethers } = require('ethers');
const { RPCPool } = require('../src/utils/rpc');
const { checkBountyFunding, assertKeeperTopology } = require('../src/utils/contracts');
const { acquireSignerFileLock } = require('../src/utils/signer-file-lock');
const IS_DN = true;
const address = n => `0x${n.toString(16).padStart(40, '0')}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const connectable = values => ({ connect() { return this; }, ...Object.fromEntries(Object.entries(values).map(([k, v]) => [k, async () => v])) });

test('both supported decision modes retain topology admission and unknown modes remain rejected', async () => {
  const env = { STRATEGY_PROFILE: IS_DN ? 'DELTA_NEUTRAL' : 'EXPOSED', RANGEMANAGER_ADDRESS: address(1), VAULT_ADDRESS: address(2),
    RANGE_STRATEGY_ENGINE_ADDRESS: address(3), TOKEN0_ADDRESS: address(4), TOKEN1_ADDRESS: address(5), AAVE_HEDGE_MANAGER_ADDRESS: address(6) };
  const old = Object.fromEntries(Object.keys(env).map(k => [k, process.env[k]])); Object.assign(process.env, env);
  try {
    let mode = 1;
    const values = { rangeManager: address(1), vault: address(2), strategyEngine: address(3), token0: address(4), token1: address(5),
      hedgeManager: address(6), pool: address(8), getAddress: address(7), profile: IS_DN ? 1 : 0, strategyVersion: IS_DN ? 3 : 2 };
    const contracts = Object.fromEntries(['rangeManager', 'vault', 'strategyEngine', 'secureBotModule', 'hedgeManager'].map(k => [k, connectable(values)]));
    contracts.strategyEngine.decisionMode = async () => mode;
    const rpc = { executeWithRetry: async fn => fn({ getCode: async () => '0x6000' }) };
    for (mode of [0, 1]) await assert.doesNotReject(assertKeeperTopology(rpc, contracts));
    for (mode of [2, -1, 100]) await assert.rejects(assertKeeperTopology(rpc, contracts), /ANALYTIC_ONLY or HYBRID/);
    mode = 0; contracts.strategyEngine.strategyVersion = async () => 99;
    await assert.rejects(assertKeeperTopology(rpc, contracts), /requires RangeStrategyEngine version/);
  } finally { for (const [k, v] of Object.entries(old)) v === undefined ? delete process.env[k] : process.env[k] = v; }
});

for (const [action, label, prefix, end] of [
  ['checkpoint', 'strategy checkpoint', 'strategyCheckpoint', "}, 'checkpointMarketState');"],
  ['deposit', 'deposit', 'deposit', 'const result = await rebalancer.processDeposit();'],
  ['rebalance', 'rebalance', 'keeper', 'const result = await rebalancer.executeRebalance(tokenId, decision.decisionHash);'],
]) {
  test(`${action} continues when optional enabled/amount/balance reads fail, but mandatory failures still stop it`, async () => {
    const code = fs.readFileSync(path.join(__dirname, '../src/keeper.js'), 'utf8');
    const start = code.indexOf(`await checkBountyFunding('${label}'`, code.indexOf('while (true)'));
    const finish = code.indexOf(end, start) + end.length;
    assert.ok(start >= 0 && finish > start);
    const source = code.slice(start, finish);
    for (const failure of [`${prefix}BountyEnabled`, `${prefix}BountyAmount`, 'balanceOf', null, 'empty', 'disabled', 'financial']) {
      let calls = 0;
      const read = method => async () => {
        if (failure === method) throw new Error('OPTIONAL_RPC_FAILURE');
        if (method.endsWith('Enabled')) return failure !== 'disabled';
        return failure === 'empty' && method === 'balanceOf' ? 0n : 1_000_000n;
      };
      const treasury = { connect() { return this; }, [`${prefix}BountyEnabled`]: read(`${prefix}BountyEnabled`), [`${prefix}BountyAmount`]: read(`${prefix}BountyAmount`) };
      const perform = async () => { if (failure === 'financial') throw new Error('MANDATORY_FINANCIAL_REJECT'); calls++; return {}; };
      const bindings = { checkBountyFunding, treasury, treasuryAddr: address(1), usdc: { connect() { return this; }, balanceOf: read('balanceOf') },
        rpcPool: { executeWithRetry: fn => fn({}), executeSignedTxWithRetry: perform },
        pending: 1n, tokenId: 1n, decision: { decisionHash: '0x' }, reasonLabel: 'TEST', console: { log() {} }, wallet: {}, strategyEngine: {},
        rebalancer: { processDeposit: perform, executeRebalance: perform } };
      const run = () => new Function(...Object.keys(bindings), `return (async () => { ${source} })()`)(...Object.values(bindings));
      if (failure === 'financial') { await assert.rejects(run(), /MANDATORY_FINANCIAL_REJECT/); assert.equal(calls, 0); }
      else { await run(); assert.equal(calls, 1, `${action}: ${failure}`); }
    }
  });
}

test('a suspended live keeper cannot lose its nonce lock or overwrite another in-flight journal', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keeper-suspended-owner-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const provider = {};
  let resumeA, enteredA, nextNonce = 7, preparedB = 0;
  const atA = new Promise(resolve => { enteredA = resolve; });
  const gateA = new Promise(resolve => { resumeA = resolve; });
  const signed = [];
  const make = label => Object.assign(Object.create(RPCPool.prototype), {
    chainId: '42161', signerAddress: wallet.address.toLowerCase(), poolName: label,
    processLockFile: path.join(dir, 'signer.lock'), pendingTxFile: path.join(dir, 'pending.json'),
    providers: [{ provider, chainVerified: true }], getProvider: () => provider,
    _ensureSignerState: async () => {}, _reconcilePendingSignedTxLocked: async () => null, _applyFeeCapPolicy: () => false,
    executeWithRetry: fn => fn(provider), withTimeout: fn => fn(),
    _broadcastSignedTransaction: async (raw, hash) => { signed.push(ethers.Transaction.from(raw)); nextNonce++; return { hash, status: 1 }; },
  });
  const a = make('A'), b = make('B');
  const prepare = first => async () => ({ wallet: {
    populateTransaction: async request => { if (first) { enteredA(); await gateA; } else preparedB++; return { ...request, nonce: nextNonce }; },
    signTransaction: request => wallet.signTransaction(request),
  }, request: { to: address(first ? 10 : 11), data: '0x', value: 0n, chainId: 42161, gasLimit: 21000n, gasPrice: 1n, type: 0 } });
  const first = a.executeSignedTxWithRetry(prepare(true), 'A'); await atA;
  const old = new Date(Date.now() - 121_000); fs.utimesSync(a.processLockFile, old, old);
  assert.equal(b._isLockOwnerAlive(JSON.parse(fs.readFileSync(a.processLockFile, 'utf8'))), true);
  const second = b.executeSignedTxWithRetry(prepare(false), 'B');
  await sleep(30); assert.equal(preparedB, 0); assert.equal(signed.length, 0);
  resumeA(); await Promise.all([first, second]);
  assert.deepEqual(signed.map(tx => tx.nonce), [7, 8]);
  assert.equal(fs.existsSync(a.pendingTxFile), false);
  assert.equal(fs.existsSync(a.processLockFile), false);
});

test('late journal mutations fail after the original operation releases its lock', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keeper-late-work-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const pool = Object.assign(Object.create(RPCPool.prototype), { processLockFile: path.join(dir, 'signer.lock'), pendingTxFile: path.join(dir, 'pending.json') });
  let resume;
  const gate = new Promise(resolve => { resume = resolve; });
  const lock = await acquireSignerFileLock(pool.processLockFile);
  const late = lock.run(async () => { await gate; pool._persistSignedTx('0x', '0x', 'late', 7); });
  lock.release();
  const next = await acquireSignerFileLock(pool.processLockFile);
  await next.run(async () => { resume(); await assert.rejects(late, { code: 'SIGNER_LOCK_LOST' }); next.assertOwned(); });
  next.release();
  assert.equal(fs.existsSync(pool.pendingTxFile), false);
  assert.throws(() => pool._clearPersistedSignedTx('0x'), { code: 'SIGNER_LOCK_LOST' });
});


test('receipt lookup completing after release cannot send a raw under the successor lock', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keeper-late-broadcast-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let resume, entered, broadcasts = 0;
  const gate = new Promise(r => { resume = r; }), ready = new Promise(r => { entered = r; });
  const provider = { getTransactionReceipt: async () => { entered(); await gate; return null; }, broadcastTransaction: async () => { broadcasts++; } };
  const entry = { provider, chainVerified: true };
  const pool = Object.assign(Object.create(RPCPool.prototype), { processLockFile: path.join(dir, 'signer.lock'), providers: [entry], _authenticatedProviderEntries: async () => [entry], withTimeout: fn => fn() });
  const lock = await acquireSignerFileLock(pool.processLockFile);
  const late = lock.run(() => pool._broadcastSignedTransaction('0x', '0x01', 'late', 0, 1));
  await ready; lock.release(); const next = await acquireSignerFileLock(pool.processLockFile);
  await next.run(async () => { resume(); await assert.rejects(late, { code: 'SIGNER_LOCK_LOST' }); });
  assert.equal(broadcasts, 0); next.release();
});
