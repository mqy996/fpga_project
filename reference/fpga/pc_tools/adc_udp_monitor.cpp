#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <array>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>

static uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
static int16_t be_i16(const uint8_t *p) {
    return static_cast<int16_t>((uint16_t(p[0]) << 8) | p[1]);
}

struct ChannelStats {
    int16_t minimum = std::numeric_limits<int16_t>::max();
    int16_t maximum = std::numeric_limits<int16_t>::min();
    int64_t sum = 0;
    uint64_t count = 0;
    void add(int16_t value) {
        if (value < minimum) minimum = value;
        if (value > maximum) maximum = value;
        sum += value;
        ++count;
    }
};

int main(int argc, char **argv) {
    std::string bind_ip = "192.168.0.3";
    unsigned seconds = 120;
    uint32_t expected_sample_rate = 500000;
    uint32_t expected_mask = 0x00ffffffu;
    unsigned groups_per_packet = 30;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--bind" && i + 1 < argc) bind_ip = argv[++i];
        else if (arg == "--seconds" && i + 1 < argc) seconds = std::stoul(argv[++i]);
        else if (arg == "--sample-rate" && i + 1 < argc)
            expected_sample_rate = std::stoul(argv[++i]);
        else if (arg == "--channels" && i + 1 < argc)
            expected_mask = std::stoul(argv[++i], nullptr, 0);
        else if (arg == "--groups" && i + 1 < argc)
            groups_per_packet = std::stoul(argv[++i]);
        else {
            std::cerr << "Usage: adc_udp_monitor [--bind 192.168.0.3] "
                         "[--seconds 120] [--sample-rate 500000] "
                         "[--channels 0x00ffffff] [--groups 30]\n";
            return 2;
        }
    }

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 2;
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) return 2;
    int receive_buffer = 64 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF,
               reinterpret_cast<const char *>(&receive_buffer), sizeof(receive_buffer));
    int timeout_ms = 500;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char *>(&timeout_ms), sizeof(timeout_ms));

    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_port = htons(56555);
    if (inet_pton(AF_INET, bind_ip.c_str(), &local.sin_addr) != 1 ||
        bind(sock, reinterpret_cast<sockaddr *>(&local), sizeof(local)) == SOCKET_ERROR) {
        std::cerr << "Cannot bind " << bind_ip << ":56555, WSA=" << WSAGetLastError() << "\n";
        closesocket(sock); WSACleanup(); return 2;
    }

    std::array<ChannelStats, 24> channels{};
    std::array<uint8_t, 1600> packet{};
    uint64_t packets = 0, lost = 0, duplicates = 0, out_of_order = 0;
    uint64_t length_errors = 0, header_errors = 0;
    uint32_t expected_seq = 1;
    bool started = false;
    unsigned enabled_count = 0;
    for (unsigned c=0;c<24;++c) enabled_count += (expected_mask>>c)&1u;
    const unsigned expected_length = 12 + 2 * enabled_count * groups_per_packet;
    auto begin = std::chrono::steady_clock::now();
    auto last_report = begin;
    std::cout << "Listening on " << bind_ip << ":56555; expected SampleRate="
              << expected_sample_rate
              << ". Start/stop using SW1/SW2, Qt, or fpga_param_cli start/stop.\n";

    while (std::chrono::steady_clock::now() - begin < std::chrono::seconds(seconds)) {
        sockaddr_in sender{}; int sender_length = sizeof(sender);
        int size = recvfrom(sock, reinterpret_cast<char *>(packet.data()),
                            int(packet.size()), 0,
                            reinterpret_cast<sockaddr *>(&sender), &sender_length);
        if (size == SOCKET_ERROR) {
            int error = WSAGetLastError();
            if (error != WSAETIMEDOUT && error != WSAEWOULDBLOCK) {
                std::cerr << "recvfrom failed, WSA=" << error << "\n";
                closesocket(sock); WSACleanup(); return 2;
            }
        } else {
            if (size != int(expected_length)) { ++length_errors; continue; }
            const uint32_t seq = be32(packet.data());
            if (!started) { expected_seq = 1; started = true; begin = std::chrono::steady_clock::now(); }
            if (seq != expected_seq) {
                if (seq == expected_seq - 1) ++duplicates;
                else if (seq > expected_seq) lost += seq - expected_seq;
                else ++out_of_order;
            }
            expected_seq = seq + 1;
            if (be32(packet.data() + 4) != expected_sample_rate ||
                be32(packet.data() + 8) != expected_mask) ++header_errors;
            size_t offset=12;
            for (unsigned group = 0; group < groups_per_packet; ++group)
                for (unsigned channel = 0; channel < 24; ++channel)
                    if ((expected_mask >> channel) & 1u) {
                        channels[channel].add(be_i16(packet.data() + offset));
                        offset += 2;
                    }
            ++packets;
        }
        auto now = std::chrono::steady_clock::now();
        if (now - last_report >= std::chrono::seconds(1)) {
            double elapsed = std::chrono::duration<double>(now - begin).count();
            std::cout << "\rpackets=" << packets << " rate="
                      << uint64_t(packets / (elapsed > 0.0 ? elapsed : 1.0))
                      << " pkt/s lost=" << lost << " format_errors="
                      << (length_errors + header_errors) << "   " << std::flush;
            last_report = now;
        }
    }

    closesocket(sock); WSACleanup();
    std::cout << "\npackets=" << packets << " lost=" << lost
              << " duplicate=" << duplicates << " out_of_order=" << out_of_order
              << " length_error=" << length_errors << " header_error=" << header_errors << "\n";
    std::cout << "CH     samples       min       max          mean\n";
    for (unsigned i = 0; i < channels.size(); ++i) {
        const auto &c = channels[i];
        const double mean = c.count ? double(c.sum) / double(c.count) : 0.0;
        std::cout << std::setw(2) << i << "  " << std::setw(10) << c.count
                  << "  " << std::setw(8) << (c.count ? c.minimum : 0)
                  << "  " << std::setw(8) << (c.count ? c.maximum : 0)
                  << "  " << std::setw(12) << std::fixed << std::setprecision(3) << mean << "\n";
    }
    const bool pass = packets > 0 && lost == 0 && duplicates == 0 && out_of_order == 0 &&
                      length_errors == 0 && header_errors == 0;
    std::cout << (pass ? "PASS: packet sequence and format are correct.\n" :
                         "FAIL: see counters above.\n");
    return pass ? 0 : 1;
}
