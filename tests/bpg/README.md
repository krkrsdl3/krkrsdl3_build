The decoder uses the unmodified libbpg 0.9.8 release from
https://bellard.org/bpg/, pinned by its archive checksum. CMake downloads it
once into the build directory. Offline builds can set
`FETCHCONTENT_SOURCE_DIR_KRKR_BPG_UPSTREAM` to an extracted copy of that release.

libbpg contains a modified older FFmpeg HEVC decoder with a different ABI from
the application's FFmpeg. During configuration, CMake prepares a private copy
of its C sources and headers, adding `krkr_bpg_` to all av_/avcodec_/avpriv_/ff_
identifiers, including token-pasting macros. The remaining unprefixed global
helpers are renamed with private compile definitions. Only libbpg.h is exposed
to the application. This separation works with both static and shared FFmpeg
and does not rely on DLL loading order or platform-specific linker flags.

Only the portable C decoder is built, with variable bit depth and prediction
support. No encoder, x265, assembly, or additional FFmpeg installation is used.
The image loader reads the first frame, handles straight RGBA and 8-bit
grayscale output, and identifies BPG by its four-byte signature, including
images stored with a .tlg/.png extension. Header queries only parse the header.
The loader initializes the decoder's shared tables once before decoding so
that synchronous and asynchronous image loads can safely overlap.

The upstream README and source headers retain the BPG-specific BSD-style
license and the bundled FFmpeg's LGPL 2.1-or-later notices. No encoder sources
are linked.

`tests/coexistence.cpp` is a small integration probe. Link it with krkr_bpg,
the application's modern libavcodec and libavutil, then run
`coexistence image.bpg output.rgba`. It holds modern HEVC and PCM contexts and
an audio frame alive across repeated BPG decodes. Compare the raw output with
the RGBA pixels from the official bpgdec utility. A symbol audit of krkr_bpg
should find only `bpg_*` and `krkr_bpg_*` global definitions, apart from
compiler-generated symbols.
