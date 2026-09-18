/* jolt_zlib.h — register the zlib this binary links, under private names.
 *
 * Every jolt binary links zlib (build.ss bld-link-libs), and the
 * runtime's java.util.zip (host/chez/java/zlib.ss) calls it. The Linux link
 * hides zlib's own names (--exclude-libs), so the runtime cannot find them by
 * name; Sforeign_symbol registers each entry point with Chez instead. The
 * names carry a jolt_z_ prefix because Chez searches loaded shared objects
 * before registered names: a plain "inflate" could bind a different zlib that
 * a program loaded.
 *
 * Pass jolt_register_zlib as Sbuild_heap's custom_init. Chez calls it after it
 * sets up the foreign-symbol table and before any boot file runs.
 *
 * The prototypes are declared here, not taken from <zlib.h>: a cross-compile
 * pack has no zlib.h. They match zlib 1.3.2, with z_streamp as void *.
 */
#ifndef JOLT_ZLIB_H
#define JOLT_ZLIB_H

extern const char *zlibVersion(void);
extern int inflateInit2_(void *strm, int windowBits, const char *version, int stream_size);
extern int inflate(void *strm, int flush);
extern int inflateEnd(void *strm);
extern int inflateReset(void *strm);
extern int inflateSetDictionary(void *strm, const unsigned char *dictionary, unsigned int dictLength);
extern int deflateInit2_(void *strm, int level, int method, int windowBits,
                         int memLevel, int strategy, const char *version, int stream_size);
extern int deflate(void *strm, int flush);
extern int deflateEnd(void *strm);
extern int deflateReset(void *strm);
extern int deflateParams(void *strm, int level, int strategy);
extern int deflateSetDictionary(void *strm, const unsigned char *dictionary, unsigned int dictLength);
extern unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
extern unsigned long adler32(unsigned long adler, const unsigned char *buf, unsigned int len);

static void jolt_register_zlib(void) {
  Sforeign_symbol("jolt_z_zlibVersion", (void *)zlibVersion);
  Sforeign_symbol("jolt_z_inflateInit2_", (void *)inflateInit2_);
  Sforeign_symbol("jolt_z_inflate", (void *)inflate);
  Sforeign_symbol("jolt_z_inflateEnd", (void *)inflateEnd);
  Sforeign_symbol("jolt_z_inflateReset", (void *)inflateReset);
  Sforeign_symbol("jolt_z_inflateSetDictionary", (void *)inflateSetDictionary);
  Sforeign_symbol("jolt_z_deflateInit2_", (void *)deflateInit2_);
  Sforeign_symbol("jolt_z_deflate", (void *)deflate);
  Sforeign_symbol("jolt_z_deflateEnd", (void *)deflateEnd);
  Sforeign_symbol("jolt_z_deflateReset", (void *)deflateReset);
  Sforeign_symbol("jolt_z_deflateParams", (void *)deflateParams);
  Sforeign_symbol("jolt_z_deflateSetDictionary", (void *)deflateSetDictionary);
  Sforeign_symbol("jolt_z_crc32", (void *)crc32);
  Sforeign_symbol("jolt_z_adler32", (void *)adler32);
}

#endif
