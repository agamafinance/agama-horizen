// Wait for zkVerify to publish the aggregation our proof landed in, then pull
// the Merkle path an EVM contract needs to prove inclusion.
//
// Submission and aggregation are separate moments. The proof is verified as soon
// as the extrinsic is finalized, but the receipt only appears when the domain's
// batch closes. On the shared public domain that happens when enough unrelated
// proofs accumulate, so this polls rather than waiting on a single event with a
// three minute timeout.
//
//   node collect.mjs          poll the domain recorded in accepted.json
//   DOMAIN_ID=n node collect.mjs
import { zkVerifySession } from 'zkverifyjs';
import fs from 'node:fs';
for (const line of fs.readFileSync('.env', 'utf-8').split('\n')) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$/);
  if (m) process.env[m[1]] ??= m[2];
}

const submitted = JSON.parse(fs.readFileSync('accepted.json', 'utf-8'));
const domainId = Number(process.env.DOMAIN_ID ?? submitted.domainId);
const aggregationId = Number(submitted.aggregationId);
const statement = submitted.statement;

const session = await zkVerifySession.start().Volta().withAccount(process.env.SEED_PHRASE);
console.log(`polling domain ${domainId} for aggregation ${aggregationId}`);

for (let attempt = 1; ; attempt++) {
  try {
    const receipt = await session.waitForAggregationReceipt(domainId, aggregationId);
    const path = await session.getAggregateStatementPath(
      receipt.blockHash, domainId, aggregationId, statement,
    );
    const out = {
      network: 'zkVerify Volta',
      domainId, aggregationId, statement,
      submittedAtBlock: submitted.blockHash,
      receiptBlockHash: receipt.blockHash,
      merklePath: path.proof,
      leafCount: path.numberOfLeaves,
      index: path.leafIndex,
      root: path.root ?? null,
    };
    fs.writeFileSync('aggregation.json', JSON.stringify(out, null, 2));
    console.log(`\npublished. wrote aggregation.json`);
    console.log(`  root        ${out.root}`);
    console.log(`  merkle path ${out.merklePath.length} sibling hashes`);
    console.log(`  leafCount   ${out.leafCount}, index ${out.index}`);
    break;
  } catch (e) {
    const msg = String(e.message || e);
    console.log(`  attempt ${attempt}: ${msg.slice(0, 80)}`);
    await new Promise((r) => setTimeout(r, 60_000));
  }
}
await session.close();
