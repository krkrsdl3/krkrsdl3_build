// libFuzzer entry point for the TJS2 source front end.
//
// Each input is fed to the lexer/parser/code generator exactly like a script
// load; syntax errors are expected and must not crash.  ASan runs alongside,
// so overruns in the lexer, parser or code generator are caught.
#include <stddef.h>
#include <stdint.h>

#include <string>
#include <vector>

#include "tjsCommHead.h"
#include "tjs.h"

namespace
{
//---------------------------------------------------------------------------
// Collects (and discards) the emitted byte code.
//---------------------------------------------------------------------------
class tFuzzDiscardStream : public TJS::tTJSBinaryStream
{
public:
    tjs_uint64 Seek(tjs_int64 offset, tjs_int whence) override
    {
        tjs_int64 base = 0;
        if (whence == TJS_BS_SEEK_CUR)
            base = (tjs_int64)Position;
        else if (whence == TJS_BS_SEEK_END)
            base = (tjs_int64)Length;
        tjs_int64 target = base + offset;
        if (target < 0)
            target = 0;
        Position = (tjs_uint64)target;
        return Position;
    }

    tjs_uint Read(void* buffer, tjs_uint read_size) override
    {
        tjs_uint n = 0;
        if (Position < Length)
            n = (tjs_uint)(Length - Position) < read_size ? (tjs_uint)(Length - Position) : read_size;
        if (n)
            memset(buffer, 0, n);
        Position += n;
        return n;
    }

    tjs_uint Write(const void* buffer, tjs_uint write_size) override
    {
        Position += write_size;
        if (Position > Length)
            Length = Position;
        return write_size;
    }

    bool Flush() override { return true; }
    tjs_uint64 GetSize() override { return Length; }

private:
    tjs_uint64 Position = 0;
    tjs_uint64 Length = 0;
};
//---------------------------------------------------------------------------
tTJS* Engine()
{
    // One engine for the whole fuzz run.  tTJS owns global, process wide
    // tables, so recreating it per input would measure construction rather
    // than the front end; it is intentionally never destroyed at exit (the
    // process is a disposable fuzz runner).
    static tTJS* engine = NULL;
    if (!engine)
        engine = new tTJS();
    return engine;
}
//---------------------------------------------------------------------------
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (size == 0 || size > 1024 * 1024)
        return 0;

    // Scripts are UTF-8.  A BOM is part of the encoding, not the script.
    size_t offset = 0;
    if (size >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
        offset = 3;

    std::string text((const char*)data + offset, size - offset);
    if (text.find('\0') != std::string::npos)
        return 0; // the engine API is NUL terminated

    try
    {
        tFuzzDiscardStream stream;
        Engine()->CompileScript(ttstr(text.c_str()).c_str(), &stream, false, false, false,
                                TJS_N("fuzz"), 0);
    }
    catch (...)
    {
        // Compile errors are the normal outcome for most mutations.
    }
    return 0;
}
