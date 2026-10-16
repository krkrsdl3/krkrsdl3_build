// Decode a BPG and PCM audio while both FFmpeg versions have live
// contexts. Link against krkr_bpg and the application's modern libavcodec.
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <vector>
extern "C" {
#include <libbpg.h>
#include <libavcodec/avcodec.h>
}

static void require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

static std::vector<uint8_t> read(const char* name)
{
    std::ifstream stream(name, std::ios::binary);
    require(stream.good(), "Cannot open input");
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

int main(int argc, char** argv)
{
    try
    {
        require(argc == 3, "Usage: coexistence image.bpg output.rgba");
        auto input = read(argv[1]);
        const std::vector<uint8_t> audio = {0xff, 0xff, 0, 0, 0xd2, 4, 0, 0x80};
        auto* codec = avcodec_find_decoder(AV_CODEC_ID_PCM_S16LE);
        require(codec != nullptr, "PCM codec missing");
        AVCodecContext* modern = avcodec_alloc_context3(codec);
        require(modern != nullptr, "Modern context allocation failed");
        modern->sample_rate = 44100;
        av_channel_layout_default(&modern->ch_layout, 2);
        require(modern && avcodec_open2(modern, codec, nullptr) == 0, "Modern codec open failed");
        const auto* hevcCodec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
        require(hevcCodec != nullptr, "HEVC codec missing");
        AVCodecContext* hevc = avcodec_alloc_context3(hevcCodec);
        require(hevc && avcodec_open2(hevc, hevcCodec, nullptr) == 0, "Modern HEVC open failed");
        AVPacket* packet = av_packet_alloc();
        AVFrame* frame = av_frame_alloc();
        AVFrame* retained = av_frame_alloc();
        require(packet && frame && retained, "Modern allocation failed");
        require(av_new_packet(packet, static_cast<int>(audio.size())) == 0, "Packet allocation failed");
        std::copy(audio.begin(), audio.end(), packet->data);
        require(avcodec_send_packet(modern, packet) == 0 &&
                avcodec_receive_frame(modern, frame) == 0, "Modern PCM decode failed");
        require(av_frame_ref(retained, frame) == 0, "Modern frame reference failed");
        av_frame_unref(frame);
        av_packet_unref(packet);

        std::vector<uint8_t> pixels;
        for (int iteration = 0; iteration < 3; ++iteration)
        {
            std::unique_ptr<BPGDecoderContext, decltype(&bpg_decoder_close)>
                bpg(bpg_decoder_open(), bpg_decoder_close);
            require(bpg && bpg_decoder_decode(bpg.get(), input.data(), static_cast<int>(input.size())) == 0,
                    "BPG decode failed");
            BPGImageInfo info = {}, header = {};
            require(bpg_decoder_get_info(bpg.get(), &info) == 0 &&
                    bpg_decoder_get_info_from_buf(&header, nullptr, input.data(),
                        std::min<int>(input.size(), BPG_DECODER_INFO_BUF_SIZE)) == 0,
                    "BPG header failed");
            require(info.width == header.width && info.height == header.height, "Image size mismatch");
            require(bpg_decoder_start(bpg.get(), BPG_OUTPUT_FORMAT_RGBA32) == 0, "BPG output failed");
            pixels.resize(static_cast<size_t>(info.width) * info.height * 4);
            for (unsigned y = 0; y < info.height; ++y)
                require(bpg_decoder_get_line(bpg.get(), pixels.data() + static_cast<size_t>(y) * info.width * 4) == 0,
                        "BPG row failed");
            // The modern AVFrame must remain usable after each BPG decode/free.
            require(av_frame_ref(frame, retained) == 0 && frame->nb_samples == 2 &&
                    std::equal(audio.begin(), audio.end(), frame->data[0]),
                    "Modern AVFrame corrupted");
            av_frame_unref(frame);
        }
        std::ofstream output(argv[2], std::ios::binary);
        output.write(reinterpret_cast<const char*>(pixels.data()), pixels.size());
        require(output.good(), "Cannot write output");
        av_frame_free(&retained);
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&modern);
        avcodec_free_context(&hevc);
        std::cout << "PASS\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
