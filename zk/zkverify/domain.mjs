// Register a domain whose batch closes on a single proof, so the aggregation
// receipt is published immediately rather than whenever the shared public domain
// happens to fill. Then submit, aggregate, and pull the Merkle path.
import { zkVerifySession, Destination, AggregateSecurityRules, ProofSecurityRules, UltrahonkVersion, UltrahonkVariant } from 'zkverifyjs';
import fs from 'node:fs';
for (const line of fs.readFileSync('.env', 'utf-8').split('\n')) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$/);
  if (m) process.env[m[1]] ??= m[2];
}
const ART = '../book_attest/target/zkv084';
const hex = (f) => fs.readFileSync(`${ART}/${f}`, 'utf-8').trim();

const session = await zkVerifySession.start().Volta().withAccount(process.env.SEED_PHRASE);

let domainId = process.env.DOMAIN_ID ? Number(process.env.DOMAIN_ID) : null;
if (domainId === null) {
  console.log('registering a domain, aggregationSize 1');
  const { transactionResult } = session.registerDomain(1, 2, {
    destination: Destination.None,
    aggregateRules: AggregateSecurityRules.Untrusted,
    proofSecurityRules: ProofSecurityRules.Untrusted,
  });
  const reg = await transactionResult;
  domainId = Number(reg.domainId);
  console.log('domain', domainId, 'registered');
  fs.writeFileSync('domain.json', JSON.stringify({ domainId }, null, 2));
}

console.log('submitting the proof to domain', domainId);
const { transactionResult: sub } = await session.verify()
  .ultrahonk({ version: UltrahonkVersion.V0_84, variant: UltrahonkVariant.ZK })
  .execute({
    proofData: {
      vk: hex('zkv_vk.hex'),
      proof: hex('zkv_proof.hex'),
      publicSignals: hex('zkv_pubs.hex').split('\n').filter(Boolean),
    },
    domainId,
  });
const r = await sub;
console.log('verified, aggregationId', r.aggregationId, 'statement', r.statement);

console.log('waiting for the aggregation receipt');
const receipt = await session.waitForAggregationReceipt(domainId, Number(r.aggregationId));
console.log('receipt at block', receipt.blockHash);

const path = await session.getAggregateStatementPath(
  receipt.blockHash, domainId, Number(r.aggregationId), r.statement,
);

const out = {
  network: 'zkVerify Volta',
  domainId,
  aggregationId: Number(r.aggregationId),
  statement: r.statement,
  submittedAtBlock: r.blockHash,
  receiptBlockHash: receipt.blockHash,
  merklePath: path.proof,
  leafCount: path.numberOfLeaves,
  index: path.leafIndex,
  root: path.root ?? null,
};
fs.writeFileSync('aggregation.json', JSON.stringify(out, null, 2));
console.log('\nwrote aggregation.json');
console.log(`  root        ${out.root}`);
console.log(`  merkle path ${out.merklePath.length} sibling hashes`);
console.log(`  leafCount   ${out.leafCount}, index ${out.index}`);
await session.close();
