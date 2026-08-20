# TwinCAT ScopeView `.svdx` / `.tcscopex` format and decoding

Status: proposed — reverse-engineered 2026-08-20 from one live recording
(`Roof.svdx`, MONETRoof roof-counter test on Becky), cross-checked against the
embedded project XML and the 160 ms decimation (128/128 samples). No official
Beckhoff format documentation was used.
Repos: BROTLib, MONETRoof

## Purpose

TwinCAT ScopeView (TE13xx) saves recordings as `.svdx` files. BROTlib needs to
read these offline — e.g. to analyse roof counter / limit-switch signals after
the fact, or to feed the position-counter fix measurements. This document
describes the file layout as observed, so a decoder can be implemented in
BROTlib (or tooling) without a running TwinCAT system.

Two file types are involved:

| Extension | Content | Sample data? |
|---|---|---|
| `.tcscopex` | ScopeView **project** — XML: channel definitions, ADS addresses, chart/axis layout, trigger config | no |
| `.svdx` | ScopeView **recording export** — binary data payload + the project XML appended | yes |

The `.tcscopex` and the XML embedded in the `.svdx` have the same schema
(`ScopeProject` root, `TwinCAT.Measurement.Scope.API.Model`). A recording can
be opened from the project file; the recorded data lives in the `.svdx`.

**A `.svdx` is self-contained for decoding**: the project XML (channel names,
ADS addresses, data types, sample time) is embedded at the end of the file, so
only the `.svdx` is required to decode recorded data. The `.tcscopex` is only
needed to open the project in the ScopeView GUI, or when no recording exists
yet.

## `.svdx` overall layout

```
0x0000  global header (incl. channel table)
0x00B4  channel block 1   (offset 180 in the observed file)
...     channel block 2..N
        embedded ScopeProject XML (from payload_size - see below)
```

The first 8 bytes are a `u64` **payload size**: everything after the 40-byte
file header up to the embedded XML (observed `107676`; XML found at
`107716 = 40 + 107676`). In general: the XML begins at
`40 + payload_size` (or at the first `<ScopeProject` byte; search for it).

## Global header (observed)

All integers little-endian. Offsets relative to file start:

| Offset | Size | Value (observed) | Meaning |
|---|---|---|---|
| 0x00 | u64 | `107676` | payload size (header is 40 bytes; XML follows at `40 + size`) |
| 0x08 | u64 | `101495` | unknown (second size? version?) |
| 0x10 | u32 | `8` | number of channels |
| 0x14 | u32 | `180` (0xB4) | offset where channel block 1 starts |
| 0x18 | u32 | `0` | padding |
| 0x1C | 8 × 20 B | see below | channel block table |
| 0xB4 | — | `"01.00.00.40"` | block 1 begins with the version string |

Channel block table — one 20-byte record per channel:

| Field | Size | Meaning |
|---|---|---|
| block size | u64 | `13437` for every block in the observed file |
| channel index | u32 | 1..8 (matches `FileHandle` in the XML) |
| block end offset | u64 | end of this block; block `k` spans `[prev_end .. end_k]`, block 1 starts at the header's data offset |

Observed end offsets: `13617, 27054, 40491, 53928, 67365, 80802, 94239`. The
8th block's end field is *not* stored (the version string of block 8 is
written there instead) — its end is the payload end (`107676`). All block
lengths are `13437 = end_k - end_{k-1}`, so the end field can be derived.

The channel→block mapping is confirmed by the embedded XML:
`AdsAcquisition.FileHandle` 1..8 ↔ block 1..8, and `AdsAcquisition.Name`
gives the symbol (`counter[1,1]`, `opened[2,2]`, …). `IndexGroup` /
`IndexOffset` give the ADS address of the source symbol (e.g. `61472 /
452448`), `DataType` the type (`BIT`), `BaseSampleTime` the sample time in
100 ns ticks (`100000` = 10 ms).

## Channel block layout (observed)

Each block is self-contained: a sub-header, then three sample series at three
resolutions (coarse → fine) covering the same time window.

```
0x000  "01.00.00.40"            version string (11 bytes)
0x00B  u64 start timestamp     100 ns ticks
0x013  u64 duration            604.1 s (10 min) in the observed file
0x01B  u64 start timestamp     repeat of the start timestamp
0x023  sub-header fields       partially decoded (see below)
0x123  sparse series           9 records × 10 B, 2.56 s cadence
0x17D  decimated series        128 records × 10 B, 160 ms cadence
0x67D  full series             128 segments × 92 B, 16 samples each @ 10 ms
```

### Sub-header

Partially decoded. Observed fields include the sample time as a `u64`
(`100000` = 10 ms) at offset ~0x03B, and a set of small counts/offsets
(`16`, `9`, `128`, `291`, `381`, `1661`, `128`, …) that mirror the series
layout (sample counts and the series' offsets). Exact meaning of every field
is not yet confirmed; the decoder should not rely on them and instead scan
for the structures below.

### Sparse series — offset 0x123 (291), 9 records

`9 × [u64 timestamp][2 bytes]`, 10 B each. Timestamps step by `25,600,000`
ticks (2.56 s). Byte 0 of the value pair is the signal value (0/1 for BIT
channels); byte 1 meaning unconfirmed (not the value — see cross-check).

### Decimated series — offset 0x17D (381), 128 records

`128 × [u64 timestamp][2 bytes]`, 10 B each. Timestamps step by `1,600,000`
ticks (160 ms). Byte 0 is the signal value; **verified byte 0 == full-series
value at the same time for 128/128 samples**. Byte 1 meaning unconfirmed.

### Full series — offset 0x67D (1661), 128 segments of 92 B

Each 92-byte segment holds 16 samples at the base sample time:

```
u64  timestamp of sample 0        (absolute, 100 ns ticks)
u64  16                           sample count (constant in observed data)
u8   value of sample 0            (0/1 for BIT)
15 × ( u32 delta_ticks, u8 value )  samples 1..15
```

`delta_ticks` is cumulative from the segment's start timestamp; observed
values are `100000, 200000, …, 1500000` (i.e. `sample k` at
`ts_start + k × 100000` = +10 ms, +20 ms, …). 128 segments × 16 samples =
2048 samples at 10 ms = 20.48 s, matching the recording duration.

## Decoding algorithm

```
read u64 payload_size @0; n_channels u32 @0x10; data_start u32 @0x14
xml_offset = search(b"<ScopeProject", 40 + payload_size)   # or payload end
parse XML → per channel: Name, FileHandle, IndexGroup/IndexOffset, DataType, BaseSampleTime

for each channel k (1..n):
    block = data[block_start_k : block_end_k]      # ends from the table; last = payload end
    # full-resolution series:
    for seg_start in 1661 .. len(block) step 92:   # or walk the sub-header's segment table
        ts0   = u64(block, seg_start + 0)
        count = u64(block, seg_start + 8)          # 16
        emit (ts0, u8(block, seg_start + 16))      # sample 0
        pos = seg_start + 17
        for k in 1..count-1:
            delta = u32(block, pos); val = u8(block, pos+4); pos += 5
            emit (ts0 + delta, val)
    # cross-check (optional): decimated series byte 0 at 160 ms cadence
```

The base sample time for the full series is `BaseSampleTime` from the XML
(`100000` ticks = 10 ms); the decoder may hard-check that the observed
`delta_ticks` are multiples of it.

## Validation on the observed file

- 8 channels decoded: `counter[1,1]`, `counter[1,2]`, `counter[2,1]`,
  `counter[2,2]` (pulsing), `opened[1..2,1..2]` (all 0).
- 2048 samples per channel @ 10 ms, 20.47 s span.
- Decimated series byte 0 equals full series at 128/128 matching samples.
- Pulse analysis (see MONETRoof `specs/plans/2026-08-20-position-counter-fix-plan.md`):
  rotation period 0.60 s, pulse widths 20–90 ms per channel, clean single
  pulses, no start-up bursts in this recording.

## Open questions / caveats

- **Timestamp epoch**: values are 100 ns ticks, but the start value
  (`0x01DD307BCCCE84A0`) does not decode to a plausible date as plain Windows
  FILETIME (it lands in Dec 2026 for a file written in Aug 2026). Only
  *deltas* are used for timing; the epoch/offset is unresolved.
- **Value byte 1** of the sparse/decimated records: not the signal value;
  possibly a flag or second value. Unconfirmed.
- **Sub-header fields** beyond version/start/duration/sample-time are
  partially decoded; do not depend on them.
- **Generality**: reverse-engineered from one recording (8 BIT channels,
  10 ms, `IncludeDataInSVDX`). Other sample times, data types (analog INT/REAL
  values), channel counts, and `SaveOption` settings may change the block
  layout. Always validate against the embedded XML and the block-size table.
- The 2.56 s sparse series is a coarse preview level-of-detail; its 9 records
  span the same window as the other two series.
