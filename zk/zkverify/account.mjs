// Generate the zkVerify account the submission runs from, and print the address
// to paste into the faucet. The seed is written to .env and is not committed.
import { mnemonicGenerate, cryptoWaitReady } from '@polkadot/util-crypto';
import { Keyring } from '@polkadot/keyring';
import fs from 'node:fs';

await cryptoWaitReady();
const seed = process.env.SEED_PHRASE ?? mnemonicGenerate(12);
const address = new Keyring({ type: 'sr25519', ss58Format: 251 }).addFromUri(seed).address;

if (!process.env.SEED_PHRASE) {
  fs.writeFileSync('.env', `SEED_PHRASE="${seed}"\n`);
  console.log('seed written to .env, which is gitignored');
}
console.log('zkVerify address :', address);
console.log('faucet           : https://zkverify-faucet.zkverify.io  (email + address, tVFY within 24h)');
