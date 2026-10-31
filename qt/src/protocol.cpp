#include "protocol.h"

#include <QSet>

namespace FpgaProtocol {
namespace {
void put16(QByteArray &buffer, quint16 value) {
    buffer.append(char((value >> 8) & 0xFF));
    buffer.append(char(value & 0xFF));
}
void put32(QByteArray &buffer, quint32 value) {
    buffer.append(char((value >> 24) & 0xFF));
    buffer.append(char((value >> 16) & 0xFF));
    buffer.append(char((value >> 8) & 0xFF));
    buffer.append(char(value & 0xFF));
}
quint16 get16(const QByteArray &buffer, int offset) {
    return (quint16(quint8(buffer[offset])) << 8) | quint8(buffer[offset + 1]);
}
quint32 get32(const QByteArray &buffer, int offset) {
    return (quint32(quint8(buffer[offset])) << 24) |
           (quint32(quint8(buffer[offset + 1])) << 16) |
           (quint32(quint8(buffer[offset + 2])) << 8) |
           quint32(quint8(buffer[offset + 3]));
}
bool validUnicast(const QHostAddress &address) {
    const quint32 word = ipv4ToWord(address);
    return address.protocol() == QAbstractSocket::IPv4Protocol &&
           word != 0 && word != 0xFFFFFFFFu && (word >> 28) != 0xEu;
}
bool contiguousMask(quint32 mask) {
    const quint32 inverse = ~mask;
    return mask != 0 && ((inverse & (inverse + 1u)) == 0);
}
}

QString commandName(Command command) {
    switch (command) {
    case Command::Discover: return QStringLiteral("DISCOVER");
    case Command::GetInfo: return QStringLiteral("GET_INFO");
    case Command::SetConfig: return QStringLiteral("SET_CONFIG");
    case Command::Start: return QStringLiteral("START");
    case Command::Stop: return QStringLiteral("STOP");
    case Command::GetStatus: return QStringLiteral("GET_STATUS");
    case Command::GetConfig: return QStringLiteral("GET_CONFIG");
    case Command::SaveConfig: return QStringLiteral("SAVE_CONFIG");
    case Command::RestoreDefault: return QStringLiteral("RESTORE_DEFAULT");
    case Command::GetFlashInfo: return QStringLiteral("GET_FLASH_INFO");
    }
    return QStringLiteral("UNKNOWN");
}

QString statusName(Status status) {
    static const QStringList names = {QStringLiteral("OK"), QStringLiteral("INVALID_CMD"),
        QStringLiteral("INVALID_LENGTH"), QStringLiteral("INVALID_PARAM"),
        QStringLiteral("INVALID_STATE"), QStringLiteral("BUSY"),
        QStringLiteral("UNSUPPORTED"), QStringLiteral("FLASH_ERROR"),
        QStringLiteral("VERIFY_ERROR"), QStringLiteral("TIMEOUT")};
    const int index = int(status);
    return index >= 0 && index < names.size() ? names.at(index) : QStringLiteral("UNKNOWN");
}

QString stateName(quint32 state) {
    switch (state) {
    case 0: return QStringLiteral("WAIT（等待初始化/ARP）");
    case 1: return QStringLiteral("FIFO_FLUSH_ASSERT");
    case 2: return QStringLiteral("FIFO_FLUSH_WAIT");
    case 3: return QStringLiteral("READY");
    case 4: return QStringLiteral("RUN（采集中）");
    case 5: return QStringLiteral("STOPPING");
    case 6: return QStringLiteral("ERROR");
    default: return QStringLiteral("UNKNOWN(%1)").arg(state);
    }
}

quint32 ipv4ToWord(const QHostAddress &address) { return address.toIPv4Address(); }
QHostAddress wordToIpv4(quint32 word) { return QHostAddress(word); }

quint32 enabledChannels(quint32 mask) {
    quint32 count = 0;
    for (int channel = 0; channel < 24; ++channel) count += (mask >> channel) & 1u;
    return count;
}

quint16 payloadBytes(const DeviceConfig &config) {
    return quint16(12u + 2u * enabledChannels(config.channelMask) * config.groupsPerPacket);
}

quint32 expectedPacketsPerSecond(const DeviceConfig &config) {
    return config.groupsPerPacket == 0 ? 0 : config.sampleRate / config.groupsPerPacket;
}

bool isValidConfig(const DeviceConfig &config, QString *error) {
    const auto fail = [error](const QString &message) { if (error) *error = message; return false; };
    if (!validUnicast(config.localIp) || !validUnicast(config.targetIp)) return fail(QStringLiteral("本机IP和目标IP必须是合法IPv4单播地址。"));
    const quint32 mask = ipv4ToWord(config.netmask);
    if (!contiguousMask(mask)) return fail(QStringLiteral("子网掩码必须连续且不能为0。"));
    if (config.localIp == config.targetIp) return fail(QStringLiteral("本机IP与目标IP不能相同。"));
    if ((ipv4ToWord(config.localIp) & mask) != (ipv4ToWord(config.targetIp) & mask)) return fail(QStringLiteral("本机IP与目标IP必须在同一子网。"));
    if (!QSet<quint32>{250000, 500000, 1000000}.contains(config.sampleRate)) return fail(QStringLiteral("采样率只能为250000、500000或1000000。"));
    if ((config.channelMask & 0xFF000000u) != 0 || enabledChannels(config.channelMask) == 0) return fail(QStringLiteral("必须启用至少一个CH0～CH23通道。"));
    if (config.groupsPerPacket < 1 || config.groupsPerPacket > 30) return fail(QStringLiteral("每包组数必须为1至30。"));
    if (payloadBytes(config) > 1472) return fail(QStringLiteral("当前通道数和每包组数使UDP负载超过1472字节。"));
    if (config.dataPort == 0) return fail(QStringLiteral("数据端口不能为0。"));
    return true;
}

QByteArray makeRequest(Command command, quint32 transactionId, const QByteArray &payload) {
    QByteArray packet; packet.reserve(16 + payload.size());
    put32(packet, quint32(command)); put32(packet, 0); put32(packet, quint32(payload.size())); put32(packet, transactionId);
    packet.append(payload); return packet;
}

QByteArray makeSetConfigPayload(const DeviceConfig &config) {
    QByteArray payload; payload.reserve(28);
    put32(payload, ipv4ToWord(config.localIp)); put32(payload, ipv4ToWord(config.netmask));
    put32(payload, ipv4ToWord(config.targetIp)); put16(payload, config.dataPort); put16(payload, 0);
    put32(payload, config.sampleRate); put32(payload, config.channelMask); put32(payload, config.groupsPerPacket);
    return payload;
}

ControlResponse parseResponse(const QByteArray &datagram, const QHostAddress &sender, quint16 senderPort) {
    ControlResponse response; response.senderIp = sender; response.senderPort = senderPort;
    if (datagram.size() < 16) return response;
    const quint32 command = get32(datagram, 0);
    if ((command & 0x80000000u) == 0) return response;
    const quint32 length = get32(datagram, 8);
    if (length != quint32(datagram.size() - 16)) return response;
    response.valid = true; response.command = Command(command & 0x7FFFFFFFu);
    response.status = Status(get32(datagram, 4)); response.transactionId = get32(datagram, 12);
    response.data = datagram.mid(16); return response;
}

bool parseConfig(const QByteArray &data, DeviceConfig *config) {
    if (!config || data.size() < 28) return false;
    config->localIp = wordToIpv4(get32(data, 0)); config->netmask = wordToIpv4(get32(data, 4));
    config->targetIp = wordToIpv4(get32(data, 8)); config->dataPort = get16(data, 12);
    config->sampleRate = get32(data, 16); config->channelMask = get32(data, 20); config->groupsPerPacket = get32(data, 24);
    if (data.size() >= 40) { config->fromFlash = get32(data, 28) != 0; config->flashSequence = get32(data, 32); config->payloadBytes = get16(data, 36); }
    else config->payloadBytes = payloadBytes(*config);
    return true;
}

bool parseSummary(const QByteArray &data, DeviceSummary *summary) {
    if (!summary || data.size() < 28) return false;
    summary->deviceId = get32(data, 0); summary->firmware = get32(data, 4); summary->hardware = get32(data, 8);
    summary->state = get32(data, 12); summary->localIp = wordToIpv4(get32(data, 16)); summary->netmask = wordToIpv4(get32(data, 20));
    summary->dataPort = get16(data, 24); summary->controlPort = get16(data, 26); return true;
}

bool parseDeviceInfo(const QByteArray &data, DeviceInfo *info) {
    if (!info || data.size() < 72) return false;
    auto &summary = info->summary;
    summary.deviceId = get32(data, 0); summary.firmware = get32(data, 4); summary.hardware = get32(data, 8);
    summary.state = get32(data, 12); summary.localIp = wordToIpv4(get32(data, 16)); summary.netmask = wordToIpv4(get32(data, 20));
    info->targetIp = wordToIpv4(get32(data, 24)); info->targetPort = get16(data, 28); info->controlPort = get16(data, 30);
    summary.dataPort = info->targetPort; summary.controlPort = info->controlPort;
    info->sampleRate = get32(data, 32); info->channelMask = get32(data, 36); info->groupsPerPacket = get32(data, 40); info->payloadBytes = get16(data, 44);
    info->arpValid = get32(data, 48) != 0;
    QStringList mac; for (int index = 0; index < 6; ++index) mac.push_back(QStringLiteral("%1").arg(quint8(data[52 + index]), 2, 16, QLatin1Char('0')));
    info->learnedMac = mac.join(QLatin1Char(':')); info->flashSequence = get32(data, 60); info->configFromFlash = get32(data, 64) != 0;
    const quint32 flags = get32(data, 68); info->flashBusy = (flags & 1u) != 0; info->flashError = (flags & 2u) != 0; info->adcError = (flags & 4u) != 0;
    return true;
}

bool parseStatus(const QByteArray &data, DeviceStatus *status) {
    if (!status || data.size() < 48) return false;
    status->state = get32(data, 0); status->packetsSent = get32(data, 4); status->fifoLevel = get32(data, 8);
    status->arpValid = get32(data, 12) != 0; status->flashBusy = get32(data, 16) != 0; status->flashError = get32(data, 20) != 0;
    status->flashCode = get32(data, 24); status->adcError = get32(data, 28) != 0; status->localIp = wordToIpv4(get32(data, 32));
    status->targetIp = wordToIpv4(get32(data, 36)); status->flashSequence = get32(data, 40); status->activeCopy = get32(data, 44); return true;
}

bool parseFlashInfo(const QByteArray &data, FlashInfo *info) {
    if (!info || data.size() < 24) return false;
    info->jedec = get32(data, 0); info->activeCopy = get32(data, 4); info->sequence = get32(data, 8);
    info->flashError = get32(data, 12) != 0; info->errorCode = get32(data, 16); info->busy = get32(data, 20) != 0; return true;
}

} // namespace FpgaProtocol
