# Architecture

Source for `Agama x Horizen - Technical Architecture.pdf` at the root of this
repository, plus the feasibility notes behind it.

## [`FEASIBILITY.md`](FEASIBILITY.md)

Horizen measured rather than read: chain throughput and gas at 0.001 gwei,
live mainnet contract addresses, what Vela does and does not support today,
where zkVerify reaches and where it does not, and PureFi confirmed callable.

Two findings in there changed the architecture rather than confirming it, and
neither is in the application we submitted. Section 2 covers the Vela one,
including a correction we owe Horizen Labs: we first concluded Vela was
deployed nowhere, quoting the limitations page, and the product page is right
and the limitations page is out of date.

## Building the PDF

```sh
./build.sh
```

`index.html` is the document. `style.css` and `page-furniture.html` carry the
header band, the footer and the page numbering. The build runs Chrome twice,
once for the body and once for the furniture, and merges the two passes with
pypdf, because headless Chrome will not put a repeating element at an exact
offset on every page any other way.

`assets/` holds the diagrams and the wordmarks. The stack diagram also exists
as an interactive flowchart in the root README, which is the version worth
reading first.
