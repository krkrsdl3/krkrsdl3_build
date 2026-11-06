// Minimal deterministic mutation driver for the TJS2 fuzz harnesses.
//
// The llvm-mingw clang does not enable libFuzzer for the *-windows-gnu target,
// so this driver provides the loop instead.  It is intentionally simple:
// mutate a seed corpus with a fixed RNG, feed every input to the harness and
// keep the current input at --last so a crash can be replayed.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <filesystem>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

namespace
{
uint64_t RngState = 0x9E3779B97F4A7C15ull;

uint64_t Rand()
{
    RngState ^= RngState << 13;
    RngState ^= RngState >> 7;
    RngState ^= RngState << 17;
    return RngState;
}

size_t RandRange(size_t n)
{
    return n ? (size_t)(Rand() % n) : 0;
}

struct tSeed
{
    std::string Name;
    std::vector<uint8_t> Data;
};

bool LoadSeeds(const std::string& dir, std::vector<tSeed>& seeds)
{
    std::error_code ec;
    std::filesystem::path root = std::filesystem::u8path(dir);
    if (!std::filesystem::is_directory(root, ec))
        return false;
    for (std::filesystem::recursive_directory_iterator it(root, ec), end; it != end; it.increment(ec))
    {
        if (ec)
            break;
        if (!it->is_regular_file(ec))
            continue;
        FILE* fp = fopen(it->path().u8string().c_str(), "rb");
        if (!fp)
            continue;
        fseek(fp, 0, SEEK_END);
        long size = ftell(fp);
        fseek(fp, 0, SEEK_SET);
        if (size > 0)
        {
            tSeed seed;
            seed.Data.resize((size_t)size);
            if (fread(seed.Data.data(), 1, (size_t)size, fp) == (size_t)size)
                seeds.push_back(std::move(seed));
        }
        fclose(fp);
    }
    return !seeds.empty();
}

void Mutate(std::vector<uint8_t>& data, const std::vector<tSeed>& seeds, size_t max_size)
{
    static const uint8_t interesting[] = { 0, 1, 2, 7, 0x0A, 0x0D, 0x20, 0x22, 0x27, 0x2F,
                                           0x3B, 0x5B, 0x5D, 0x7B, 0x7D, 0x25, 0x40, 0x80,
                                           0xFF };
    int rounds = 1 + (int)RandRange(8);
    for (int r = 0; r < rounds; r++)
    {
        if (data.empty())
            data.push_back(0);
        switch (RandRange(8))
        {
            case 0:
                data[RandRange(data.size())] ^= (uint8_t)(1u << RandRange(8));
                break;
            case 1:
                data[RandRange(data.size())] = (uint8_t)Rand();
                break;
            case 2:
                data[RandRange(data.size())] = interesting[RandRange(sizeof(interesting))];
                break;
            case 3:
                if (data.size() < max_size)
                    data.insert(data.begin() + (ptrdiff_t)RandRange(data.size() + 1),
                                interesting[RandRange(sizeof(interesting))]);
                break;
            case 4:
                if (data.size() > 1)
                {
                    size_t pos = RandRange(data.size());
                    size_t len = 1 + RandRange(std::min<size_t>(32, data.size() - pos));
                    data.erase(data.begin() + (ptrdiff_t)pos, data.begin() + (ptrdiff_t)(pos + len));
                }
                break;
            case 5:
                if (data.size() < max_size)
                {
                    size_t pos = RandRange(data.size());
                    size_t len = 1 + RandRange(std::min<size_t>(32, data.size() - pos));
                    std::vector<uint8_t> copy(data.begin() + (ptrdiff_t)pos,
                                              data.begin() + (ptrdiff_t)(pos + len));
                    size_t at = RandRange(data.size() + 1);
                    data.insert(data.begin() + (ptrdiff_t)at, copy.begin(), copy.end());
                }
                break;
            case 6:
            {
                const tSeed& other = seeds[RandRange(seeds.size())];
                if (!other.Data.empty())
                {
                    size_t src = RandRange(other.Data.size());
                    size_t len = 1 + RandRange(std::min<size_t>(64, other.Data.size() - src));
                    size_t at = RandRange(data.size() + 1);
                    size_t room = max_size > data.size() ? max_size - data.size() : 0;
                    len = std::min(len, room);
                    data.insert(data.begin() + (ptrdiff_t)at, other.Data.begin() + (ptrdiff_t)src,
                                other.Data.begin() + (ptrdiff_t)(src + len));
                }
                break;
            }
            case 7:
                if (data.size() > 2)
                    data.resize(1 + RandRange(data.size()));
                break;
        }
    }
}
} // namespace

int main(int argc, char* argv[])
{
    std::string seeds_dir;
    std::string last_path = "out/fuzz-last.bin";
    long iterations = 10000;
    size_t max_size = 1024 * 1024;
    uint64_t rng = 0x9E3779B97F4A7C15ull;

    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--seeds") == 0 && i + 1 < argc)
            seeds_dir = argv[++i];
        else if (strcmp(argv[i], "--last") == 0 && i + 1 < argc)
            last_path = argv[++i];
        else if (strcmp(argv[i], "--iterations") == 0 && i + 1 < argc)
            iterations = atol(argv[++i]);
        else if (strcmp(argv[i], "--max-size") == 0 && i + 1 < argc)
            max_size = (size_t)atol(argv[++i]);
        else if (strcmp(argv[i], "--rng") == 0 && i + 1 < argc)
            rng = strtoull(argv[++i], NULL, 0);
    }

    if (seeds_dir.empty())
    {
        fprintf(stderr, "usage: %s --seeds DIR [--iterations N] [--last PATH] [--rng N]\n",
                argv[0]);
        return 2;
    }

    std::vector<tSeed> seeds;
    if (!LoadSeeds(seeds_dir, seeds))
    {
        fprintf(stderr, "no seeds under %s\n", seeds_dir.c_str());
        return 2;
    }
    RngState = rng ? rng : 1;

    fprintf(stderr, "seeds=%zu iterations=%ld\n", seeds.size(), iterations);
    for (long i = 0; i < iterations; i++)
    {
        const tSeed& seed = seeds[RandRange(seeds.size())];
        std::vector<uint8_t> data = seed.Data;
        Mutate(data, seeds, max_size);

        FILE* fp = fopen(last_path.c_str(), "wb");
        if (fp)
        {
            if (!data.empty())
                fwrite(data.data(), 1, data.size(), fp);
            fclose(fp);
        }

        LLVMFuzzerTestOneInput(data.data(), data.size());
        if ((i + 1) % 1000 == 0)
            fprintf(stderr, "iterations=%ld\n", i + 1);
    }
    return 0;
}
