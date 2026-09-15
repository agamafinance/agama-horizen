// Agama x Horizen - Book revision delta circuit.
//
// Closes the one gap the attestation circuit cannot close on its own.
//
// book_attest proves that a published risk surface honestly describes whatever
// book was committed. It cannot prove that a *revision* of the book is an
// honest evolution of the previous one. Without that, an originator could
// publish a second root containing a loan that had already defaulted, stamped
// with an old commitment date, and the surface over it would still verify.
//
// This circuit proves that the new root is derived from the previous root by
// operations that are actually allowed:
//
//   - a position keeps its slot for the life of the book. Slots are never
//     reused, so a repaid loan holds its slot at zero principal rather than
//     freeing it for a backdated replacement.
//   - a carried position may not change obligor, maturity, or the date it was
//     first committed. Its principal may only amortise down, never re-advance.
//     Its next payment date may only move forward.
//   - the amount due at an unchanged payment date may not be revised down, so
//     the bar cannot be lowered once it is set.
//   - status may move in any direction. Deterioration has to be expressible,
//     that is the whole point of a revision.
//   - a position in a slot that was empty is genuinely new, and must carry a
//     commitment date at or after the moment the previous root reached the
//     chain. This is the constraint that makes backdating impossible rather
//     than merely expensive.

global N: u32 = 64;

pub struct Loan {
    position_id: Field, // permanent slot identity, 0 means the slot is unused
    obligor: Field,
    principal: u64,
    maturity_ts: u64,
    due_ts: u64,
    due_amount: u64,
    status: u8,
    committed_ts: u64,
    salt: Field,
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

fn main(
    old_book: [Loan; N],
    new_book: [Loan; N],
    old_root: pub Field,
    prev_commit_ts: pub u64, // block timestamp at which old_root was committed
    as_of: pub u64,
) -> pub Field {
    let mut old_leaves: [Field; N] = [0; N];
    let mut new_leaves: [Field; N] = [0; N];
    for i in 0..N {
        old_leaves[i] = leaf_hash(old_book[i]);
        new_leaves[i] = leaf_hash(new_book[i]);
    }
    assert(merkle_root(old_leaves) == old_root, "old root mismatch");

    for i in 0..N {
        let o = old_book[i];
        let n = new_book[i];

        if o.position_id != 0 {
            // Carried position. The slot is bound for the life of the book.
            assert(n.position_id == o.position_id, "slot reassigned");
            assert(n.obligor == o.obligor, "obligor changed");
            assert(n.maturity_ts == o.maturity_ts, "maturity changed");
            assert(n.committed_ts == o.committed_ts, "commitment date rewritten");
            assert(n.salt == o.salt, "salt rotated");
            assert(n.principal <= o.principal, "principal re-advanced");
            assert(n.due_ts >= o.due_ts, "payment date moved backwards");
            // The bar a position will be judged against cannot be lowered in
            // place. A genuine prepayment reduces principal and restates the
            // schedule at the next cycle, which moves due_ts forward.
            if n.due_ts == o.due_ts {
                assert(n.due_amount >= o.due_amount, "amount due lowered in place");
            }
        } else if n.position_id != 0 {
            // Newly opened slot. It cannot claim to predate the root it
            // replaces, so a loan whose outcome is already known cannot be
            // inserted into a clean history.
            assert(n.committed_ts >= prev_commit_ts, "new position backdated");
            assert(n.committed_ts <= as_of, "new position committed after as_of");
        } else {
            // Both empty. Nothing may hide in an unused slot.
            assert(n.principal == 0, "principal in an unidentified slot");
            assert(n.obligor == 0, "obligor in an unidentified slot");
            assert(n.committed_ts == 0, "timestamp in an unidentified slot");
        }
    }

    merkle_root(new_leaves)
}
