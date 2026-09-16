// Submit the Agama risk-surface proof to zkVerify, and collect the aggregation
// an EVM chain can check inclusion against.
//
//   node account.mjs     once, to create the account and print it for the faucet
//   node submit.mjs      once the account holds tVFY
//
// The proof is the same one the registry verifies directly on Horizen, in the zk
// flavour bb produces with --zk, which is the only flavour the UltraHonk pallet
// accepts. Rebuild the artefacts with ../prove.sh --zkverify.
import { zkVerifySession, ZkVerifyEvents, UltrahonkVersion, UltrahonkVariant } from 'zkverifyjs';
import fs from 'node:fs';
import 'dotenv/config';

const ART = '../book_attest/target/zkv';
const DOMAIN = Number(process.env.DOMAIN_ID ?? 0);

const hex = (f) => fs.readFileSync(`${ART}/${f}`, 'utf-8').trim();
const proof = hex('zkv_proof.hex');
const vk = hex('zkv_vk.hex');
const publicSignals = hex('zkv_pubs.hex').split('\n').filter(Boolean);

console.log(`proof  ${(proof.length - 2) / 2} bytes`);
console.log(`vk     ${(vk.length - 2) / 2} bytes`);
console.log(`pubs   ${publicSignals.length} field elements`);
console.log(`       as_of ${BigInt(publicSignals[0])}, positions ${BigInt(publicSignals[2])}, ` +
            `principal ${Number(BigInt(publicSignals[3])) / 1e6} USDC`);

const session = await zkVerifySession.start().Volta().withAccount(process.env.SEED_PHRASE);

const { events, transactionResult } = await session
  .verify()
  .ultrahonk({ version: UltrahonkVersion.V0_84, variant: UltrahonkVariant.ZK })
  .execute({ proofData: { vk, proof, publicSignals }, domainId: DOMAIN });

events.on(ZkVerifyEvents.IncludedInBlock, (d) =>
  console.log(`included in block, aggregationId ${d.aggregationId}, statement ${d.statement}`));
events.on(ZkVerifyEvents.Finalized, () => console.log('finalized on zkVerify'));
events.on(ZkVerifyEvents.ErrorEvent, (e) => console.error('error', e));

const result = await transactionResult;
console.log(`\nverified on zkVerify at block ${result.blockHash}`);
console.log(`domain ${DOMAIN}, aggregationId ${result.aggregationId}`);

// The path an EVM contract needs to prove this proof was in the batch.
const path = await session.getAggregateStatementPath(
  result.blockHash, DOMAIN, result.aggregationId, result.statement,
);

const out = {
  network: 'Volta',
  domainId: DOMAIN,
  aggregationId: result.aggregationId,
  statement: result.statement,
  blockHash: result.blockHash,
  merklePath: path.proof,
  leafCount: path.numberOfLeaves,
  index: path.leafIndex,
};
fs.writeFileSync('aggregation.json', JSON.stringify(out, null, 2));
console.log('\nwrote aggregation.json');
console.log('feed it to ZkVerifyRiskSurface.admit on Base Sepolia:');
console.log(`  admit(${out.aggregationId}, <${out.merklePath.length} sibling hashes>, ` +
            `${out.leafCount}, ${out.index}, <17 public inputs>)`);

await session.close();
