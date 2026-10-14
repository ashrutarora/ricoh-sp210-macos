/*
 * rastertoricohsp210 - CUPS filter for the Ricoh SP 210 / SP 211 series on macOS.
 *
 * CUPS raster (8-bit greyscale, colour space K, 600 dpi) in, the printer's "GDI" stream out.
 * The stream format is documented in FORMAT.md.
 *
 *   rastertoricohsp210 job user title copies options [file]
 *
 * Copyright (C) 2026 Ashrut Arora
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "jbig.h"

#ifdef RICOH_DITHER
/* Built with `make RICOH_DITHER=1`: halftone exactly as Ricoh's own filter does, so the output
   can be compared with it byte for byte (tools/verify.sh). dither_ricoh.h is generated from the
   user's own copy of Ricoh's filter by tools/extract_ricoh_dither.py and is never committed. */
#include "dither_ricoh.h"

/* Ricoh's filter maps grey through a LUT that, at default brightness and contrast, works out
   as trunc((g / 255.0) * 255.0) in x87 arithmetic (one lower for 144 levels), with entry 255
   overwritten by entry 254. */
static unsigned char grey_map(unsigned char g)
{
  static unsigned char lut[256];
  static int ready;
  if (!ready) {
    int i;
    for (i = 0; i < 256; i++) {
      /* exact value of d * 255 for the double d = i / 255.0, without x87: p is the rounded
         product and e its rounding error, so the true product is below p when e < 0 */
      double d = i / 255.0, p = d * 255.0, e = fma(d, 255.0, -p);
      int t = (int)p;
      if ((double)t == p && e < 0) t--;
      lut[i] = (unsigned char)t;
    }
    lut[255] = lut[254];
    ready = 1;
  }
  return lut[g];
}
/* Ricoh starts each band's dither rows at band * rows-in-this-band, so the shorter last
   band of a page is out of phase with the rest. Kept, for identical output. */
#define DITHER_FIRST_ROW(band, rows) ((band) * (rows))
#else
#include "dither_own.h"
#define grey_map(g) (g)
#define DITHER_FIRST_ROW(band, rows) ((band) * BAND_ROWS)
#endif

#define BAND_ROWS 256
#define MAX_WIDTH 16384   /* pixels; 27 inches at 600 dpi, far past any paper this printer takes */
#define MAX_HEIGHT 65535  /* rows; the page header field is 16 bits */
#define PAPER_CUSTOM 0xff
#define PAPER_UNKNOWN 0xfe

/* ---- output helpers (everything on the wire is big-endian) ---- */

static void put16(unsigned char *p, unsigned v) { p[0] = v >> 8; p[1] = v; }
static void put32(unsigned char *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void out(const void *buf, size_t len)
{
  if (fwrite(buf, 1, len, stdout) != len) {
    fputs("ERROR: Unable to write print data\n", stderr);
    exit(1);
  }
}

static void *xrealloc(void *p, size_t n)
{
  if (!(p = realloc(p, n))) {
    fputs("ERROR: Out of memory\n", stderr);
    exit(1);
  }
  return p;
}

/* ---- the printer's codes for paper size, paper type and input tray ---- */

typedef struct { const char *name; int id; } strid_t;

static const strid_t paper_sizes[] = {
  {"A3", 8}, {"B4", 12}, {"A4", 9}, {"B5", 13}, {"A5", 11}, {"A6", 70}, {"B6", 88},
  {"Tabloid", 17}, {"Legal", 5}, {"Oficio", 132}, {"Letter", 1}, {"GovernmentLG", 124},
  {"GovernmentLetter", 130}, {"8x13", 122}, {"Foolscap", 14}, {"Folio", 123}, {"Executive", 7},
  {"EngQuatro", 131}, {"HalfLetter", 6}, {"Env10", 20}, {"EnvMonarch", 37}, {"EnvC5", 28},
  {"EnvC6", 31}, {"EnvDL", 27}, {"8K", 125}, {"16K", 119}, {"16K1", 120}, {"16K2", 121},
  {"12x18", 127}, {"11x15", 46}, {"11x14", 128}, {"10x15", 129}, {"10x14", 16}, {NULL, 0}};

static const strid_t paper_types[] = {
  {"PlainRecycled", 0}, {"Thin", 13}, {"Plain1", 1}, {"Plain2", 18}, {"Recycled", 2},
  {"Color", 3}, {"Special", 19}, {"MiddleThick", 14}, {"Printed", 20}, {"Preprinted", 5},
  {"Prepunched", 6}, {"Letterhead", 4}, {"Bond", 8}, {"Cardstock", 9}, {"Thick", 12},
  {"Thick2", 15}, {"Label", 7}, {"OHP", 11}, {"Envelope", 16}, {NULL, 0}};

static const strid_t input_trays[] = {
  {"Auto", 0}, {"Manual", 1}, {"Tray1", 2}, {"Tray2", 3}, {"Tray3", 4}, {"Tray4", 5}, {NULL, 0}};

static int lookup(const strid_t *t, const char *name, int fallback)
{
  if (!name) return fallback;
  for (; t->name; t++)
    if (!strcmp(t->name, name)) return t->id;
  return fallback;
}

static int paper_size_code(const char *name)
{
  if (!name || !*name) return -1;
  if (!strncmp(name, "Custom.", 7)) return PAPER_CUSTOM;
  return lookup(paper_sizes, name, -1);
}

/* ---- job settings ---- */

typedef struct {
  int paper_size;   /* from the job's PageSize, or -1: then each page's raster header decides */
  int paper_type, input_tray;
  int toner_save;
  const char *title;
} job_t;

/* An option's value: the job's own setting first, then the queue's PPD default (CUPS passes
   the PPD in $PPD), then nothing. */
static const char *option(const char *name, int nopts, cups_option_t *opts, ppd_file_t *ppd)
{
  const char *v = cupsGetOption(name, nopts, opts);
  ppd_choice_t *c;
  if (v) return v;
  if (ppd && (c = ppdFindMarkedChoice(ppd, name))) return c->choice;
  return NULL;
}

static void send_job_header(const job_t *job, const cups_page_header2_t *h)
{
  unsigned char b[0x78] = {0}, e[0xa8] = {0};
  size_t n;

  memcpy(b, "GDIJ", 4);
  put32(b + 4, sizeof b);
  put16(b + 0x08, 100);
  put16(b + 0x0a, h->NumCopies);
  b[0x0c] = job->toner_save;
  b[0x0d] = 0;                       /* edge smoothing: the PPD offers none */
  put16(b + 0x10, h->Collate ? 8 : 0);
  put16(b + 0x12, sizeof e);
  put16(b + 0x20, 0x100);
  put16(b + 0x22, 2);
  n = strlen(job->title);
  if (n > sizeof b - 0x38) n = sizeof b - 0x38;
  memcpy(b + 0x38, job->title, n);
  out(b, sizeof b);

  memcpy(e, "GJET", 4);
  put32(e + 4, sizeof e);
  out(e, sizeof e);
}

static void send_page_header(const job_t *job, const cups_page_header2_t *h, unsigned page,
                             unsigned aligned_width, unsigned bands)
{
  unsigned char b[0x40] = {0};
  unsigned top = h->PageSize[1] > h->ImagingBoundingBox[3] ? h->PageSize[1] - h->ImagingBoundingBox[3] : 0;
  unsigned xmargin = h->ImagingBoundingBox[0] * h->HWResolution[0] / 72;
  unsigned ymargin = top * h->HWResolution[1] / 72;
  int size = job->paper_size >= 0 ? job->paper_size : paper_size_code(h->cupsPageSizeName);
  int i;

  memcpy(b, "GDIP", 4);
  put32(b + 4, sizeof b);
  b[0x08] = size >= 0 ? size : PAPER_UNKNOWN;
  b[0x09] = job->input_tray;
  b[0x0a] = job->paper_type;
  b[0x0b] = 0;                       /* output tray */
  put16(b + 0x0c, aligned_width);
  put16(b + 0x0e, h->cupsHeight);
  for (i = 0; i < 4; i++) put16(b + 0x10 + 2 * i, ymargin);
  for (i = 0; i < 4; i++) put16(b + 0x18 + 2 * i, xmargin);
  b[0x20] = 1;
  b[0x21] = 1;                       /* simplex */
  put16(b + 0x22, page);
  put16(b + 0x36, bands);
  /* paper size in micrometres, computed through float and truncated */
  put32(b + 0x38, (uint32_t)(float)(h->PageSize[0] / 72.0L * 25.4L * 1000.0L));
  put32(b + 0x3c, (uint32_t)(float)(h->PageSize[1] / 72.0L * 25.4L * 1000.0L));
  out(b, sizeof b);
}

/* ---- halftone: 24x24 ordered dither, one pattern per grey level ---- */

static void halftone(const unsigned char *grey, unsigned width, unsigned rows, unsigned first_row,
                     unsigned char *bits)
{
  unsigned rowbytes = width / 8, y, x;

  memset(bits, 0, (size_t)rowbytes * rows);
  for (y = 0; y < rows; y++) {
    const unsigned char *g = grey + (size_t)y * width;
    unsigned char *o = bits + (size_t)y * rowbytes;
    unsigned dy = (first_row + y) % 24;
    for (x = 0; x < width; x++) {
      unsigned char pat = dither_patterns[g[x]][dy][(x / 8) % 3];
      if (pat & (0x80 >> (x & 7))) o[x >> 3] |= 0x80 >> (x & 7);
    }
  }
}

/* ---- JBIG band ---- */

typedef struct { unsigned char *buf; size_t len, cap; } sink_t;

static void sink_write(unsigned char *start, size_t len, void *file)
{
  sink_t *s = file;
  if (s->len + len > s->cap) {
    s->cap = (s->len + len) * 2;
    s->buf = xrealloc(s->buf, s->cap);
  }
  memcpy(s->buf + s->len, start, len);
  s->len += len;
}

static void send_band(unsigned char *bits, unsigned width, unsigned rows, int first, int last)
{
  struct jbg_enc_state enc;
  unsigned char *planes[1] = {bits};
  unsigned char hdr[0x20] = {0};
  sink_t s = {0};
  size_t padded;

  jbg_enc_init(&enc, width, rows, 1, planes, sink_write, &s);
  jbg_enc_options(&enc, JBG_ILEAVE | JBG_SMID, JBG_LRLTWO, BAND_ROWS, 0, 0);
  jbg_enc_out(&enc);
  jbg_enc_free(&enc);

  /* the data after the 20-byte BIH is zero-padded to a multiple of 32 bytes */
  padded = s.len;
  if ((padded - 20) & 31) padded = ((padded + 11) & ~(size_t)31) + 20;
  s.buf = xrealloc(s.buf, padded);
  memset(s.buf + s.len, 0, padded - s.len);

  memcpy(hdr, "GDIB", 4);
  put32(hdr + 4, (last ? 2 : 0) | (first ? 1 : 0));
  put32(hdr + 8, padded);
  put16(hdr + 0x18, width);
  put16(hdr + 0x1a, rows);
  out(hdr, sizeof hdr);
  out(s.buf, padded);
  free(s.buf);
}

static int finish(int status)
{
  if (fflush(stdout) != 0) {
    fputs("ERROR: Unable to write print data\n", stderr);
    return 1;
  }
  return status;
}

int main(int argc, char *argv[])
{
  cups_raster_t *ras;
  cups_page_header2_t h;
  cups_option_t *opts = NULL;
  ppd_file_t *ppd = NULL;
  int nopts, fd = 0;
  unsigned page = 0;
  job_t job;
  const char *v;

  if (argc < 6 || argc > 7) {
    fprintf(stderr, "Usage: %s job user title copies options [file]\n", argv[0]);
    return 1;
  }
  if (argc == 7 && (fd = open(argv[6], O_RDONLY)) < 0) {
    perror("ERROR: Unable to open raster file");
    return 1;
  }

  nopts = cupsParseOptions(argv[5], 0, &opts);
  if ((v = getenv("PPD")) && (ppd = ppdOpenFile(v))) {
    ppdMarkDefaults(ppd);
    cupsMarkOptions(ppd, nopts, opts);
  }
  job.paper_size = paper_size_code(cupsGetOption("PageSize", nopts, opts));
  job.paper_type = lookup(paper_types, option("MediaType", nopts, opts, ppd), 0);
  job.input_tray = lookup(input_trays, option("InputSlot", nopts, opts, ppd), 0);
  v = option("TonerSave", nopts, opts, ppd);
  job.toner_save = v && (!strcasecmp(v, "true") || !strcasecmp(v, "on") || !strcasecmp(v, "yes"));
  job.title = argv[3];

  ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
  while (cupsRasterReadHeader2(ras, &h)) {
    unsigned aw, bands;
    unsigned char *line, *grey, *bits;
    unsigned band, y;

    /* Header fields come from the job, so check them before sizing any buffer: the width and
       height go into 16-bit fields, and each line is copied into an aligned-width row. */
    if (h.cupsBitsPerPixel != 8 || h.cupsColorSpace != CUPS_CSPACE_K ||
        h.HWResolution[0] != 600 || h.HWResolution[1] != 600 ||
        h.cupsWidth < 1 || h.cupsWidth > MAX_WIDTH || h.cupsBytesPerLine != h.cupsWidth ||
        h.cupsHeight < 1 || h.cupsHeight > MAX_HEIGHT) {
      fprintf(stderr, "ERROR: Unsupported raster: %ux%u at %ux%u dpi, %u bytes per line, %u bpp, "
              "colour space %u\n", h.cupsWidth, h.cupsHeight, h.HWResolution[0], h.HWResolution[1],
              h.cupsBytesPerLine, h.cupsBitsPerPixel, h.cupsColorSpace);
      if (page) out("JIDG", 4);
      return finish(1);
    }
    aw = (((h.cupsWidth + 7) & ~7u) + 127) & ~127u;
    bands = (h.cupsHeight + BAND_ROWS - 1) / BAND_ROWS;
    if (++page == 1) send_job_header(&job, &h);
    fprintf(stderr, "PAGE: %u %u\n", page, h.NumCopies);
    send_page_header(&job, &h, page, aw, bands);

    line = malloc(h.cupsBytesPerLine);
    grey = malloc((size_t)aw * BAND_ROWS);
    bits = malloc((size_t)aw / 8 * BAND_ROWS);
    if (!line || !grey || !bits) { fputs("ERROR: Out of memory\n", stderr); return 1; }

    for (band = 0; band < bands; band++) {
      unsigned rows = band + 1 < bands ? BAND_ROWS : h.cupsHeight - band * BAND_ROWS;
      memset(grey, 0, (size_t)aw * BAND_ROWS);
      for (y = 0; y < rows; y++) {
        unsigned i;
        if (cupsRasterReadPixels(ras, line, h.cupsBytesPerLine) != h.cupsBytesPerLine) {
          fputs("ERROR: Short raster page\n", stderr);
          out("GDIC CANCEL     ", 16);
          out("JIDG", 4);
          return finish(1);
        }
        for (i = 0; i < h.cupsBytesPerLine; i++) {
          line[i] = grey_map(line[i]);
          if (job.toner_save) line[i] >>= 1;
        }
        memcpy(grey + (size_t)y * aw, line, h.cupsBytesPerLine);
      }
      halftone(grey, aw, rows, DITHER_FIRST_ROW(band, rows), bits);
      send_band(bits, aw, rows, band == 0, band + 1 == bands);
    }
    free(line); free(grey); free(bits);
  }
  cupsRasterClose(ras);
  if (fd > 0) close(fd);
  if (ppd) ppdClose(ppd);
  cupsFreeOptions(nopts, opts);
  if (!page) {
    fputs("ERROR: No pages in raster\n", stderr);
    return finish(1);
  }
  out("JIDG", 4);
  return finish(0);
}
