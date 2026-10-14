# jbigkit 2.1 (library files only)

From https://www.cl.cam.ac.uk/~mgk25/jbigkit/ by Markus Kuhn, GPL-2.0-or-later (see COPYING).
sha256 of jbigkit-2.1.tar.gz: de7106b6bfaf495d6865c7dd7ac6ca1381bd12e0d81405ea81e7f2167263d932

Modified 2026-10-14: `jbig.c` can skip `jbg_buf_remove_zeros()` when built with
`-DJBG_KEEP_TRAILING_ZEROS=1`, so stripes keep the 0x00 bytes the arithmetic coder wrote before its
final flush, as Ricoh's printer driver does. Output still decodes the same with any T.82 decoder.
