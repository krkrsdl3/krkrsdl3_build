// Host hooks needed by tjs2 in the standalone fuzz targets.
#include "tjsCommHead.h"
#include "Platform.h"

#include <chrono>
#include <cstdio>

void TVPConsoleLog(const tjs_char* format, ...)
{
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    printf("\n");
    va_end(args);
}

tjs_uint32 TVPGetRoughTickCount32()
{
    return (tjs_uint32)TVPGetRoughTickCount();
}

tjs_uint64 TVPGetRoughTickCount()
{
    auto now = std::chrono::steady_clock::now();
    return (tjs_uint64)std::chrono::duration_cast<std::chrono::milliseconds>(
                           now.time_since_epoch())
        .count();
}
