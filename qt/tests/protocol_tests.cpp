#include "protocol.h"

#include <QCoreApplication>
#include <QDebug>

namespace {
void append32(QByteArray &b, quint32 value) {
    b.append(char(value >> 24)); b.append(char(value >> 16)); b.append(char(value >> 8)); b.append(char(value));
}
void append16(QByteArray &b, quint16 value) { b.append(char(value >> 8)); b.append(char(value)); }
bool expect(bool value, const char *message) { if (!value) qCritical() << "FAIL:" << message; return value; }
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    using namespace FpgaProtocol;
    bool pass = true;
    DeviceConfig config; config.localIp = QHostAddress(QStringLiteral("192.168.0.2")); config.netmask = QHostAddress(QStringLiteral("255.255.255.0")); config.targetIp = QHostAddress(QStringLiteral("192.168.0.3")); config.dataPort = 56555; config.sampleRate = 500000; config.channelMask = 0x00ffffff; config.groupsPerPacket = 30;
    pass &= expect(isValidConfig(config), "default config should be valid");
    pass &= expect(payloadBytes(config) == 1452, "24 channels x 30 groups payload");
    config.sampleRate = 123456; pass &= expect(!isValidConfig(config), "unsupported sample rate must fail"); config.sampleRate = 250000;
    config.channelMask = 0x000000ff; config.groupsPerPacket = 10; const QByteArray payload = makeSetConfigPayload(config);
    pass &= expect(payload.size() == 28, "set config must be 28 bytes");
    const QByteArray request = makeRequest(Command::SetConfig, 0x11223344u, payload);
    pass &= expect(request.size() == 44, "request header plus payload size");
    QByteArray response; append32(response, 0x80000007u); append32(response, 0); append32(response, 40); append32(response, 0x11223344u);
    append32(response, 0xC0A80002); append32(response, 0xFFFFFF00); append32(response, 0xC0A80003); append16(response, 56555); append16(response, 0); append32(response, 250000); append32(response, 0x000000ff); append32(response, 10); append32(response, 0); append32(response, 4); append16(response, 172); append16(response, 0);
    const auto parsed = parseResponse(response, QHostAddress(QStringLiteral("192.168.0.2")), 56556);
    pass &= expect(parsed.valid && parsed.command == Command::GetConfig && parsed.transactionId == 0x11223344u, "response header parse");
    DeviceConfig decoded; pass &= expect(parseConfig(parsed.data, &decoded), "config response parse");
    pass &= expect(decoded.sampleRate == 250000 && decoded.channelMask == 0xff && decoded.groupsPerPacket == 10 && decoded.payloadBytes == 172, "config fields parse");
    return pass ? 0 : 1;
}
