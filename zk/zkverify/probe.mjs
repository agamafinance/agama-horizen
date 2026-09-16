import { zkVerifySession, UltrahonkVersion, UltrahonkVariant } from 'zkverifyjs';
import fs from 'node:fs';
for (const line of fs.readFileSync('.env','utf-8').split('\n')) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$/); if (m) process.env[m[1]] ??= m[2];
}
const ART='../book_attest/target/zkv084';
const hex=(f)=>fs.readFileSync(`${ART}/${f}`,'utf-8').trim();
const proof=hex('zkv_proof.hex'), vk=hex('zkv_vk.hex');
const publicSignals=hex('zkv_pubs.hex').split('\n').filter(Boolean);

const session = await zkVerifySession.start().Volta().withAccount(process.env.SEED_PHRASE);
for (const version of [UltrahonkVersion.V0_84, UltrahonkVersion.V3_0, UltrahonkVersion.Legacy]) {
  for (const variant of [UltrahonkVariant.ZK, UltrahonkVariant.Plain]) {
    try {
      const { transactionResult } = await session.verify()
        .ultrahonk({ version, variant })
        .execute({ proofData: { vk, proof, publicSignals }, domainId: 0 });
      const r = await transactionResult;
      console.log(`  ${version}/${variant}  ACCEPTE  agg=${r.aggregationId} statement=${r.statement}`);
      fs.writeFileSync('accepted.json', JSON.stringify({version,variant,...r},null,2));
      await session.close(); process.exit(0);
    } catch (e) {
      console.log(`  ${version}/${variant}  refuse : ${String(e.message||e).slice(0,70)}`);
    }
  }
}
await session.close();
