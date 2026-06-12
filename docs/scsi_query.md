The emulated SCSI hard drive answers an INQUIRY (opcode $12) as a Seagate ST-225N — vendor " SEAGATE", product
  "ST225" plus a final character derived from the drive's SCSI ID (rtl/scsi.v:264-281).

  Details of the response:

  - Bytes 8–15 (vendor field): " SEAGATE" (leading space, so it's slightly offset from a standard 8-byte vendor
  string), followed by padding spaces through byte 25.
  - Bytes 26–31 (product field): "ST225" + ("N" + SCSI ID). So a drive at ID 0 reports ST225N, ID 1 reports
  ST225O, and so on — the per-ID letter bump is marked // TESTING. ElectronAsh. in the source, presumably so each
  drive looks distinct to formatter utilities. With your disks at IDs 6 and 5, they'd read as ST225T and ST225S.
  - Byte 4 (additional length) is 32; everything else is zeros, meaning peripheral type $00 = direct-access disk,
  non-removable.

  The real ST-225N was a 20MB drive, but capacity is reported separately via READ CAPACITY from the actual
  mounted image size, so the identity string is purely cosmetic to the firmware/driver. There's also a second
  INQUIRY block further down the file (around rtl/scsi.v:864-967, the AppleCD/CD-ROM variant) used by the other
  device personality, but the hard drive path is the Seagate one.
