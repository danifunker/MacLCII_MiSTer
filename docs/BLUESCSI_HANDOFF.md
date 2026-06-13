# BlueSCSI Toolbox Protocol — Implementation Handoff

## Goal

Implement the **BlueSCSI Toolbox protocol** in an emulated SCSI hard disk so the
guest Macintosh can copy files to and from a host-side **shared folder**
(e.g. `shared/`), using the standard Mac-side client application
("BlueSCSI SD Transfer", from https://bluescsi.com/toolbox).

This document is self-contained: it specifies every command, byte layout, phase
sequence, and edge case needed for a complete, client-compatible implementation.
It is intentionally **platform- and language-agnostic** — the implementing agent
decides which files, modules, and language to use based on the target codebase
(e.g. FPGA core + soft-CPU/MCU/HPS firmware split). The protocol logic itself
needs filesystem access, so it belongs on whichever side of your design services
storage I/O (support MCU, ARM/HPS, host bridge, etc.). The fabric/SCSI state
machine only needs the small hooks listed in "Integration requirements".

Reference (for background only; this doc supersedes the need to read it):
BlueSCSI Toolbox Developer Docs —
https://github.com/BlueSCSI/BlueSCSI-v2/wiki/Toolbox-Developer-Docs
This spec describes Toolbox **API v0** plus the large-transfer extensions, as
implemented and tested against the real Mac client in the Snow emulator.

---

## 1. Integration requirements (SCSI target side)

These are the only changes needed in the SCSI command/phase engine itself:

1. **CDB length:** opcodes `0xD0`–`0xD9` are vendor-specific commands that must
   be parsed as **10-byte CDBs**. If your engine derives CDB length from the
   opcode group (top 3 bits), these would normally fall in a vendor group —
   special-case them to 10 bytes.

2. **Dispatch:** route opcodes `0xD0`–`0xD9` to the Toolbox handler instead of
   the normal disk command path. (Snow intercepts them at the controller level
   for *any* selected target ID, with a single global Toolbox state; per-device
   handling also works — the client talks to the device it detected.)

3. **Detection mode page:** the disk target's MODE SENSE(6) (`0x1A`) must serve
   vendor **page 0x31** — see §2. Without this page the Mac client will not
   recognize the device as Toolbox-capable.

4. **Phases:** only standard phases are used: Command, Data-In, Data-Out,
   Status, Message-In. Status bytes: GOOD = `0x00`, CHECK CONDITION = `0x02`.

5. **Data-Out contract** (how every "host receives data" command works):
   - The command is first executed with *no* payload available. The handler
     responds "need N bytes of Data-Out".
   - The target enters the Data-Out phase and collects exactly N bytes from
     the initiator.
   - The handler is then invoked a **second time** with the same CDB plus the
     N received bytes, and this time returns a status.
   - If N = 0, skip the bus phase and immediately re-invoke with an empty
     payload (per SPC-3 §6.7, an empty Data-Out buffer is not an error).

6. **Data-In contract:** the handler returns a byte buffer; the target sends it
   in Data-In phase and then reports status GOOD. A response *shorter* than the
   initiator requested is legal and meaningful (see GET FILE, §4.3).

7. Toolbox error cases simply return **CHECK CONDITION status without setting
   specific sense data** (the real client tolerates this). Your device should
   still implement REQUEST SENSE (`0x03`) normally for the rest of the disk
   emulation.

---

## 2. Client detection — MODE SENSE page 0x31

The Mac client identifies a Toolbox-capable device by reading MODE SENSE(6)
vendor page `0x31` and checking for the magic string.

**Page 0x31 payload (page data only, 42 bytes):**

```
"BlueSCSI is the BEST STOLEN FROM BLUESCSI\0"
```

(41 ASCII characters + 1 NUL terminator = 42 bytes. The leading
`BlueSCSI is the BEST` prefix is what matters for detection; the rest is an
in-joke in the official firmware. Reproduce the full string verbatim.)

**Wrapping:** this payload is returned inside a normal MODE SENSE(6) response:

```
Byte 0      Mode data length (total length - 1)
Byte 1      Medium type            (0x00 for fixed disk)
Byte 2      Device-specific param  (0x00)
Byte 3      Block descriptor len   (8, or 0 if DBD bit set in CDB[1] bit 3)
[8-byte block descriptor unless DBD: density 0x00, 3 bytes #blocks = 0,
 1 reserved, 3 bytes block size = 0x000200 (512)]
Then the page:
  +0        Page code   (0x31)
  +1        Page length (42 = 0x2A)
  +2..+44   The 42-byte string above
```

Truncate the whole response to the allocation length in CDB[4]. Also include
page 0x31 when responding to the "all pages" request (page code `0x3F`).

The client may also issue INQUIRY first; any sane disk INQUIRY works (Snow
reports peripheral type 0x00, ANSI SCSI-2, vendor/product/revision strings —
nothing Toolbox-specific).

---

## 3. Host-side state

The Toolbox handler needs only:

| State          | Description |
|----------------|-------------|
| `shared_dir`   | Path to the host shared folder. If unset/absent → every file command fails with CHECK CONDITION. |
| `file`         | At most **one** open file handle (used for both download and upload). |
| `debug_flag`   | Boolean toggled by command 0xD6 (can be a no-op). |

### Directory enumeration rules (critical for correctness)

The protocol is **index-based across separate commands** (count → list →
get-by-index), so enumeration must be *deterministic and stable*:

- Enumerate `shared_dir` (non-recursive), **sort entries by filename**
  (raw readdir order is not stable and will corrupt index-based access).
- **Filter out** hidden entries (names starting with `.`) and any name that
  can't be decoded.
- Indices are 0-based positions in the sorted, filtered list.
- The file count is returned in a single byte → cap the listing at 255 entries
  (fewer is fine; the official firmware has lower limits due to RAM).
- Filenames are exchanged in **MacRoman** encoding, max **32 bytes**
  (truncate longer names; convert from/to the host encoding — see §6).
- Directories may appear in the listing (typed as such) but v0 has no
  "enter directory" command — only top-level files are transferable.

---

## 4. Command reference

All multi-byte integers are **big-endian**. All CDBs are 10 bytes; unspecified
CDB bytes are ignored. "→ Data-In(n)" means respond with n bytes then status
GOOD; "CHECK" means status CHECK CONDITION.

### Opcode summary

| Opcode | Name                  | Data phase | Purpose |
|--------|-----------------------|------------|---------|
| 0xD0   | LIST FILES            | Data-In    | Directory listing of shared folder |
| 0xD1   | GET FILE              | Data-In    | Read file chunk (host → Mac) |
| 0xD2   | COUNT FILES           | Data-In    | Number of entries |
| 0xD3   | SEND FILE PREP        | Data-Out 33| Create file, open for write (Mac → host) |
| 0xD4   | SEND FILE DATA        | Data-Out   | Write chunk at offset |
| 0xD5   | SEND FILE END         | none       | Close/flush the upload |
| 0xD6   | TOGGLE DEBUG          | Data-In or none | Get/set debug flag |
| 0xD7   | LIST CDS              | —          | CD image switching — *optional*, see §4.9 |
| 0xD8   | SET NEXT CD           | —          | CD image switching — *optional*, see §4.9 |
| 0xD9   | DEVICE INFO           | Data-In    | List devices / capabilities |

### 4.1 — 0xD2 COUNT FILES

- No shared dir configured → CHECK.
- → Data-In(1): single byte = number of entries (sorted/filtered list, §3).

### 4.2 — 0xD0 LIST FILES

- No shared dir configured → CHECK.
- → Data-In(40 × count). One fixed **40-byte entry** per file, in sorted order:

| Offset | Size | Field |
|--------|------|-------|
| 0      | 1    | Index (0-based, matches GET FILE index) |
| 1      | 1    | Type: `0x01` = file, `0x00` = directory |
| 2      | 32   | Filename, MacRoman, NUL-padded (unused bytes zero) |
| 34     | 2    | Zero (padding; guarantees NUL termination of name) |
| 36     | 4    | File size in bytes, u32 big-endian (0 for directories) |

The client uses the size field to drive its download loop.

### 4.3 — 0xD1 GET FILE (download, host → Mac)

CDB:

| Byte | Meaning |
|------|---------|
| 1    | File index (from listing) |
| 2–5  | Offset, u32 BE, in units of **4096-byte blocks** |
| 6    | Block count to transfer (number of 4 KB blocks). `0` means `1` (v0 backward compatibility) |

Behavior:

- When **offset == 0**: close any previously open file, resolve the index
  against a fresh sorted enumeration, and open that file for reading.
  Open failure → CHECK.
- Seek to `offset × 4096`, read up to `block_count × 4096` bytes.
- → Data-In(actual bytes read). A **short response** (fewer bytes than
  requested, including 0) signals EOF to the client; close the file handle
  when a read returns 0 bytes.
- No open file / seek or read error → CHECK.

Baseline v0 clients request one 4 KB block at a time (CDB[6] = 0); clients that
saw the `CAP_LARGE_TRANSFERS` capability request multiple blocks per command.
Size your transfer buffer for the largest count you intend to honor — **32 KB
(8 blocks) is the working ceiling the capability flags were designed around**.

### 4.4 — 0xD3 SEND FILE PREP (upload, step 1)

- No shared dir configured → CHECK.
- First invocation (no payload): request **Data-Out of exactly 33 bytes**
  (32-byte max filename + NUL terminator).
- Second invocation (with 33-byte payload): filename = bytes up to the first
  NUL, decoded from MacRoman. Create/truncate that file in the shared folder
  and keep it open for writing. → status GOOD. Create failure or no NUL found
  → CHECK.
- **Hardening (do this even though the reference implementations don't):**
  reject names containing path separators or `..` so the guest cannot write
  outside the shared folder.

### 4.5 — 0xD4 SEND FILE DATA (upload, step 2, repeated)

CDB — two encodings, receiver must support **both**:

| Byte | Meaning |
|------|---------|
| 1–2  | *Legacy:* byte count for this chunk, u16 BE (used only when CDB[6] == 0; v0 chunks are ≤ 512 bytes) |
| 3–5  | Offset, 24-bit BE, in units of **512-byte blocks** (both encodings) |
| 6    | *Block encoding:* chunk size = CDB[6] × 512 bytes. `0` → use the legacy CDB[1–2] byte count |

Behavior:

- Compute `bytes = CDB[6] > 0 ? CDB[6] × 512 : u16(CDB[1..3])`.
- No file open (no preceding 0xD3) → CHECK.
- First invocation: request Data-Out of exactly `bytes`.
- Second invocation (with payload): seek to `offset × 512`, write the `bytes`
  received → GOOD. Write/seek failure → CHECK.
- With `CAP_LARGE_SEND` advertised, clients send up to **64 blocks = 32 KB**
  per command; the final partial chunk uses the legacy byte-count encoding.

### 4.6 — 0xD5 SEND FILE END

- **No data phase** — go directly to status (this matches real BlueSCSI
  firmware; do not request Data-Out here).
- Flush and close the open upload file → GOOD. No open file or flush failure
  → CHECK.

### 4.7 — 0xD6 TOGGLE DEBUG

| CDB[1] | Action |
|--------|--------|
| 0      | Set: debug_flag = (CDB[2] != 0) → status GOOD |
| ≠0     | Get: → Data-In(1), byte = debug_flag (0/1) |

Safe to implement as a stored boolean with no other effect.

### 4.8 — 0xD9 DEVICE INFO

CDB[1] = subcommand; CDB[8] = allocation length (`0` → 8 for backward
compatibility; 1–8 → that many bytes; **> 8 → CHECK**).

- **Subcommand 0x00 — LIST DEVICES:** → Data-In(alloc): 8 bytes, one per SCSI
  ID 0–7. Value = device type for an ID this unit emulates, `0xFF` = no device.
  Type values follow the SCSI2SD `S2S_CFG` device-type enum; the ones you need:
  `0x00` = fixed disk, `0x02` = optical/CD. A single hard disk at ID 0 returns
  `00 FF FF FF FF FF FF FF`.
- **Subcommand 0x01 — GET CAPABILITIES:** → Data-In(alloc):

  | Byte | Value |
  |------|-------|
  | 0    | Toolbox API version = `0` |
  | 1    | Capability flags: `0x01` = CAP_LARGE_TRANSFERS (multi-block 0xD1 reads), `0x02` = CAP_LARGE_SEND (32 KB 0xD4 block-encoded sends) |
  | 2–7  | Reserved, zero |

  Advertise `0x03` (both flags) if your buffers support 32 KB transfers;
  advertise `0x00` to force the slow 512 B/4 KB v0 paths.
- Unknown subcommand → CHECK.

v0 clients may never send 0xD9 — the baseline single-block/512-byte paths must
work without any capability negotiation.

### 4.9 — 0xD7 / 0xD8 (CD image switching) — optional

Not needed for file sharing. Snow deliberately omits them (its UI swaps CD
images directly) and returns CHECK for them, which the client handles fine.
Implement only if your core exposes multiple CD images to switch between; in
that case take the CDB definitions from the BlueSCSI Toolbox wiki page
referenced at the top.

Any other 0xD0–0xD9 opcode or malformed command → CHECK CONDITION.

---

## 5. Expected client traffic (for testing/validation)

**Detection:** INQUIRY → MODE SENSE(6) page 0x31 (string check) →
optionally 0xD9/0 and 0xD9/1.

**Download (Mac pulls a file):**
```
0xD2 (count) → 0xD0 (list, picks index & learns size)
loop: 0xD1 index, offset=0,1,2,... blocks   until short/empty Data-In
```

**Upload (Mac pushes a file):**
```
0xD3 + 33-byte name payload
loop: 0xD4 (offset advances in 512-byte units) + data payload
0xD5
```

Validation checklist:

- [ ] Client's transfer window detects the device (page 0x31 string exact).
- [ ] Listing shows files with correct names (incl. accented chars) and sizes.
- [ ] Download of a file > 4 KB completes and matches byte-for-byte.
- [ ] Download works with CDB[6] = 0 (v0) and > 1 (large transfers).
- [ ] Upload of a file not a multiple of 512 bytes completes (final partial
      chunk arrives in legacy encoding) and matches byte-for-byte.
- [ ] Re-uploading an existing filename overwrites it.
- [ ] Two listings in a row return identical ordering (stable sort).
- [ ] With no shared folder configured, commands fail with CHECK CONDITION
      and the disk otherwise functions normally.
- [ ] Guest cannot escape the shared folder via crafted filenames.

---

## 6. MacRoman ↔ host text conversion

Filenames cross the bus in MacRoman:

- Bytes `0x00–0x7F`: identical to ASCII (`0x0D` = carriage return / newline).
- Bytes `0x80–0xFF`: the MacRoman high table (Ä Å Ç É Ñ Ö Ü á à â ä ã å ç é è
  … — use any published MacRoman ↔ Unicode mapping table; it is a fixed
  128-entry table).
- Host → Mac: NFC-normalize first (macOS filesystems hand out NFD, which
  won't map), then map per-character; replace unmappable characters with `?`.
- Mac → host: map per-character to Unicode/UTF-8.

---

## 7. Gotchas (each of these broke something once)

1. **Unstable directory order** silently corrupts index-based access — sort.
2. **0xD0–0xD9 must be read as 10-byte CDBs**; a wrong CDB length desyncs the
   command phase.
3. The **mode page 0x31 string must be byte-exact** and properly wrapped in a
   full MODE SENSE(6) response.
4. **0xD5 has no data phase.** Requesting Data-Out for it hangs the client.
5. **0xD3 payload is exactly 33 bytes**, not 32.
6. **0xD1 offsets are 4096-byte units; 0xD4 offsets are 512-byte units.**
   Don't unify them.
7. EOF on download is signaled by a **short Data-In**, not by an error status.
8. `0xD1 offset==0` and `0xD3` must each **implicitly close** any previously
   open file — only one transfer file is ever open.
9. CDB[6] = 0 means "1 block" for 0xD1 but "use legacy byte count" for 0xD4.
10. Filter dotfiles; macOS drops `.DS_Store` into every shared folder.

