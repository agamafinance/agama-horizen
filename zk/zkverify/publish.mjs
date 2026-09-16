// Close the loop: publish the aggregation our statement sits in, then pull the
// Merkle path an EVM contract needs.
//
// Verification and publication are separate acts on zkVerify. The proof is
// verified when the extrinsic finalizes, but the aggregation only becomes a root
// an EVM chain can check once somebody calls aggregate() on it. On a domain with
// Untrusted aggregate rules, that somebody can be us.
import { zkVerifySession } from 'zkverifyjs';
import fs from 'node:fs';
for (const line of fs.readFileSync('.env', 'utf-8').split('\n')) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$/);
  if (m) process.env[m[1]] ??= m[2];
}
const domainId = Number(process.env.DOMAIN_ID);
const aggregationId = Number(process.env.AGGREGATION_ID);
const statement = process.env.STATEMENT;

const session = await zkVerifySession.start().Volta().withAccount(process.env.SEED_PHRASE);
console.log(`publishing domain ${domainId} aggregation ${aggregationId}`);

const { transactionResult } = session.aggregate(domainId, aggregationId);
const res = await transactionResult;
console.log('published at block', res.blockHash);

const path = await session.getAggregateStatementPath(
  res.blockHash, domainId, aggregationId, statement,
);

const out = {
  network: 'zkVerify Volta',
  domainId, aggregationId, statement,
  receiptBlockHash: res.blockHash,
  merklePath: path.proof,
  leafCount: path.numberOfLeaves,
  index: path.leafIndex,
  root: path.root ?? res.root ?? null,
};
fs.writeFileSync('aggregation.json', JSON.stringify(out, null, 2));
console.log('\nwrote aggregation.json');
console.log(`  root        ${out.root}`);
console.log(`  merkle path ${out.merklePath.length} sibling hashes`);
console.log(`  leafCount   ${out.leafCount}, index ${out.index}`);
await session.close();
