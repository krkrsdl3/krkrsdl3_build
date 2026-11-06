// libFuzzer entry point for the TJS2 byte code loader.
//
// The loader is fed arbitrary bytes through the same entry point the engine
// uses for precompiled scripts.  It must reject malformed input without
// reading out of bounds; ASan runs alongside.
#include <stddef.h>
#include <stdint.h>

#include "tjsCommHead.h"
#include "tjs.h"
#include "tjsByteCodeLoader.h"
#include "tjsScriptBlock.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (size < 8 || size > 64 * 1024 * 1024)
        return 0;

    static tTJS* engine = NULL;
    if (!engine)
        engine = new tTJS();

    try
    {
        TJS::tTJSByteCodeLoader loader;
        TJS::tTJSScriptBlock* block =
            loader.ReadByteCode(engine, TJS_N("fuzz"), (const tjs_uint8*)data, size);
        if (block)
            block->Release();
    }
    catch (...)
    {
    }
    return 0;
}
