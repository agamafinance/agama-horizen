#!/usr/bin/env python3
"""Generate circuit inputs for the Agama credit book scenarios.

Three books over the same 22 positions, in the same permanent slots:

  t0     the book as first committed, one position already 90+ days past due
  t1     the same book one period on, after two positions deteriorated
  evil   t1 with an extra position inserted into a free slot, stamped with an
         origination date from before the previous root was committed. This is
         exactly the move the delta circuit exists to refuse.

Emits Prover.toml for book_attest (t0, t1) and book_delta (t0 -> t1, t0 -> evil).
"""
import json
import os
import sys
from collections import defaultdict

N = 64
DAY = 86400
# Defaults match the committed fork-test fixtures. A live deployment overrides
# them, because on a real chain the valuation dates are decided by the chain:
# the book is committed first, and only then can it be valued.
AS_OF_0 = int(os.environ.get("AGAMA_AS_OF_0", 1789500000))
AS_OF_1 = int(os.environ.get("AGAMA_AS_OF_1", AS_OF_0 + 30 * DAY))
PREV_COMMIT_TS = int(os.environ.get("AGAMA_PREV_COMMIT", AS_OF_0 - DAY))

HERE = os.path.dirname(os.path.abspath(__file__))
FIELDS = ["committed_ts", "due_amount", "due_ts", "maturity_ts", "obligor",
          "position_id", "principal", "salt", "status"]

OBLIGORS = [str((0xA0A0A0 + i * 0x1111) * 1000003 + 7) for i in range(15)]

#      obligor, principal $, months to maturity, days to next due, status t0, status t1
SPECS = [
    (0,  750_000,  9, 12, 0, 0),
    (0,  300_000,  4,  6, 0, 0),
    (1,  420_000, 18, 21, 0, 0),
    (2,  380_000,  6,  3, 0, 1),   # rolls 1-30 dpd
    (3,  350_000, 24, 28, 0, 0),
    (4,  300_000,  2,  9, 0, 0),
    (5,  275_000, 11, 17, 1, 2),   # deteriorates
    (6,  260_000,  3,  1, 0, 0),
    (7,  240_000, 14, 25, 0, 0),
    (8,  210_000,  8, 14, 0, 0),
    (9,  190_000,  1,  5, 0, 0),
    (10, 175_000, 30, 40, 0, 0),
    (11, 160_000,  5, 11, 1, 1),
    (12, 140_000,  7, 19, 0, 0),
    (13, 120_000, 20, 33, 0, 0),
    (14, 110_000,  4,  8, 4, 4),
    (1,   95_000, 10, 22, 0, 0),
    (3,   80_000, 16, 27, 0, 0),
    (5,   70_000,  2,  4, 0, 0),
    (8,   60_000, 12, 16, 0, 0),
    (10,  45_000,  6, 10, 0, 0),
    (12,  30_000,  3,  2, 0, 0),
]

EMPTY = dict(position_id="0", obligor="0", principal=0, maturity_ts=0, due_ts=0,
             due_amount=0, status=0, committed_ts=0, salt="0")


def position(slot, oi, p, mm, dd, status, period):
    principal = p * 1_000_000
    maturity = AS_OF_0 + mm * 30 * DAY
    # Payment dates are measured from the valuation date of the period they
    # belong to, so a live run with a compressed clock still produces a
    # populated forward calendar instead of an empty one.
    due = (AS_OF_1 if period else AS_OF_0) + dd * DAY
    due_amt = int(principal * 0.09 / 12) + (principal if due >= maturity else 0)
    return dict(
        position_id=str(slot + 1),
        obligor=OBLIGORS[oi],
        principal=principal,
        maturity_ts=maturity,
        due_ts=due,
        due_amount=due_amt,
        status=status,
        # every original position was committed before the t0 root reached the chain
        committed_ts=AS_OF_0 - (120 + slot * 7) * DAY,
        salt=str(1000 + slot * 31),
    )


def book(period, evil=False):
    out = []
    for slot, (oi, p, mm, dd, s0, s1) in enumerate(SPECS):
        out.append(position(slot, oi, p, mm, dd, s0 if period == 0 else s1, period))
    while len(out) < N:
        out.append(dict(EMPTY))
    if evil:
        # A position that has already gone bad, dropped into the first free
        # slot and stamped with an origination date from before the previous
        # commitment. book_attest alone would happily prove a surface over it.
        out[len(SPECS)] = dict(
            position_id=str(len(SPECS) + 1),
            obligor=OBLIGORS[2],
            principal=900_000 * 1_000_000,
            maturity_ts=AS_OF_0 + 12 * 30 * DAY,
            due_ts=AS_OF_1 + 15 * DAY,
            due_amount=6_750 * 1_000_000,
            status=0,
            committed_ts=AS_OF_0 - 200 * DAY,   # backdated, the whole point
            salt="7777",
        )
    return out


def write_prover(path, header, books):
    with open(path, "w") as fh:
        fh.write(header)
        for name, b in books:
            for loan in b:
                fh.write(f"[[{name}]]\n")
                for k in FIELDS:
                    fh.write(f'{k} = "{loan[k]}"\n')
                fh.write("\n")


def expected(b, as_of):
    act = [l for l in b if l["principal"]]
    lad = [0] * 5
    delq = [0] * 5
    due30 = 0
    newest = 0
    for l in act:
        h = max(0, l["maturity_ts"] - as_of)
        i = 0 if h <= 30 * DAY else 1 if h <= 90 * DAY else 2 if h <= 180 * DAY else 3 if h <= 365 * DAY else 4
        lad[i] += l["principal"]
        delq[l["status"]] += l["principal"]
        if as_of <= l["due_ts"] <= as_of + 30 * DAY:
            due30 += l["due_amount"]
        newest = max(newest, l["committed_ts"])
    e = defaultdict(int)
    for l in act:
        e[l["obligor"]] += l["principal"]
    return dict(as_of=as_of, count=len(act), total=sum(l["principal"] for l in act),
                ladder=lad, due30=due30, delinquent=delq, top1=max(e.values()),
                newest=newest)


def main(which):
    if which in ("t0", "t1"):
        period = 0 if which == "t0" else 1
        as_of = AS_OF_0 if period == 0 else AS_OF_1
        b = book(period)
        write_prover(os.path.join(HERE, "book_attest/Prover.toml"),
                     f'as_of = "{as_of}"\n\n', [("loans", b)])
        exp = expected(b, as_of)
        json.dump(exp, open(os.path.join(HERE, f"scenarios/{which}.json"), "w"), indent=2)
        print(json.dumps(exp, indent=2))
    elif which in ("delta", "evil"):
        evil = which == "evil"
        hdr = (f'old_root = "0"\nprev_commit_ts = "{PREV_COMMIT_TS}"\n'
               f'as_of = "{AS_OF_1}"\n\n')
        write_prover(os.path.join(HERE, "book_delta/Prover.toml"), hdr,
                     [("old_book", book(0)), ("new_book", book(1, evil=evil))])
        print(f"{which}: book_delta/Prover.toml written "
              f"(old_root placeholder, filled by prove.sh)")
    else:
        sys.exit(f"unknown scenario {which}")


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "scenarios"), exist_ok=True)
    main(sys.argv[1] if len(sys.argv) > 1 else "t0")
