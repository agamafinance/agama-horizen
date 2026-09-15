// Agama x Horizen - Credit book risk-surface attestation circuit.
//
// Proves that a published set of risk aggregates is the honest evaluation of a
// privately held loan book, and returns that set as public outputs bound to a
// Merkle commitment of the book.
//
// The circuit deliberately does NOT prove that the loans are good. No circuit
// can. It proves that whatever the originator committed to, the published
// numbers describe it exactly, and that no leaf was backdated past the as-of
// date it is published under. Loan quality is established afterwards, in
// public, by the forward cash calendar this circuit emits.

global N: u32 = 64; // book slots per attestation batch
global DAY: u64 = 86400;

pub struct Loan {
    position_id: Field, // permanent slot identity, 0 means the slot is unused.
                        // Bound for the life of the book so that a repaid loan
                        // cannot free its slot for a backdated replacement.
                        // See the book_delta circuit.
    obligor: Field,     // salted obligor identifier, stable across attestations
    principal: u64,     // outstanding principal, 6dp stablecoin units
    maturity_ts: u64,   // final maturity, unix seconds
    due_ts: u64,        // next scheduled payment date, unix seconds
    due_amount: u64,    // amount contractually due at due_ts
    status: u8,         // 0 current | 1 1-30dpd | 2 31-60 | 3 61-90 | 4 90+/default
    committed_ts: u64,  // when this leaf was first committed on-chain
    salt: Field,        // blinding factor
}

pub struct RiskSurface {
    root: Field,            // Merkle commitment to the book
    count: u64,             // active positions
    total_principal: u64,   // outstanding principal
    ladder: [u64; 5],       // principal maturing <=30d, <=90d, <=180d, <=365d, >365d
    due_next_30d: u64,      // forward cash calendar: contractual inflow over 30 days
    delinquent: [u64; 5],   // principal by delinquency bucket, index == status
    top1: u64,              // largest single-obligor exposure
    max_committed_ts: u64,  // newest commitment timestamp in the batch
}

fn leaf_hash(l: Loan) -> Field {
    std::hash::pedersen_hash([
        l.position_id,
        l.obligor,
        l.principal as Field,
        l.maturity_ts as Field,
        l.due_ts as Field,
        l.due_amount as Field,
        l.status as Field,
        l.committed_ts as Field,
        l.salt,
    ])
}

fn merkle_root(leaves: [Field; N]) -> Field {
    let mut level: [Field; N] = leaves;
    let mut width: u32 = N;
    for _ in 0..6 {
        let half = width / 2;
        let mut next: [Field; N] = [0; N];
        for i in 0..N {
            if i < half {
                next[i] = std::hash::pedersen_hash([level[2 * i], level[2 * i + 1]]);
            }
        }
        level = next;
        width = half;
    }
    level[0]
}

fn main(loans: [Loan; N], as_of: pub u64) -> pub RiskSurface {
    let mut leaves: [Field; N] = [0; N];
    for i in 0..N {
        leaves[i] = leaf_hash(loans[i]);
    }

    let mut count: u64 = 0;
    let mut total_principal: u64 = 0;
    let mut ladder: [u64; 5] = [0; 5];
    let mut due_next_30d: u64 = 0;
    let mut delinquent: [u64; 5] = [0; 5];
    let mut max_committed_ts: u64 = 0;

    for i in 0..N {
        let l = loans[i];
        if l.principal != 0 {
            count += 1;
            total_principal += l.principal;

            // A leaf may never claim to have been committed after the as-of
            // date it is published under. Commit-before-outcome, enforced.
            assert(l.committed_ts <= as_of, "leaf committed after as_of");
            if l.committed_ts > max_committed_ts {
                max_committed_ts = l.committed_ts;
            }

            let horizon = if l.maturity_ts > as_of { l.maturity_ts - as_of } else { 0 };
            if horizon <= 30 * DAY {
                ladder[0] += l.principal;
            } else if horizon <= 90 * DAY {
                ladder[1] += l.principal;
            } else if horizon <= 180 * DAY {
                ladder[2] += l.principal;
            } else if horizon <= 365 * DAY {
                ladder[3] += l.principal;
            } else {
                ladder[4] += l.principal;
            }

            if (l.due_ts >= as_of) & (l.due_ts <= as_of + 30 * DAY) {
                due_next_30d += l.due_amount;
            }

            assert(l.status < 5, "bad status");
            for b in 0..5 {
                if l.status as u32 == b {
                    delinquent[b] += l.principal;
                }
            }
        }
    }

    // Concentration: largest exposure aggregated per obligor.
    let mut top1: u64 = 0;
    for i in 0..N {
        if loans[i].principal != 0 {
            let mut exposure: u64 = 0;
            for j in 0..N {
                if (loans[j].principal != 0) & (loans[j].obligor == loans[i].obligor) {
                    exposure += loans[j].principal;
                }
            }
            if exposure > top1 {
                top1 = exposure;
            }
        }
    }

    RiskSurface {
        root: merkle_root(leaves),
        count,
        total_principal,
        ladder,
        due_next_30d,
        delinquent,
        top1,
        max_committed_ts,
    }
}
