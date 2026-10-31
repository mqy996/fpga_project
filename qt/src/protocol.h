#pragma once

#include <QByteArray>
#include <QAbstractSocket>
#include <QHostAddress>
#include <QString>
#include <QtGlobal>

namespace FpgaProtocol {

constexpr quint16 kControlPort = 56556;
constexpr quint16 kDefaultDataPort = 56555;
constexpr quint32 kDefaultMask = 0x00FFFFFFu;

enum class Command : quint32 {
    Discover = 1, GetInfo = 2, SetConfig = 3, Start = 4, Stop = 5,
    GetStatus = 6, GetConfig = 7, SaveConfig = 8, RestoreDefault = 9,
    GetFlashInfo = 10
};

enum class Status : quint32 {
    Ok = 0, InvalidCommand = 1, InvalidLength = 2, InvalidParameter = 3,
    InvalidState = 4, Busy = 5, Unsupported = 6, FlashError = 7,
    VerifyError = 8, Timeout = 9
};

struct DeviceConfig {
    QHostAddress localIp {QStringLiteral("192.168.0.2")};
    QHostAddress netmask {QStringLiteral("255.255.255.0")};
    QHostAddress targetIp {QStringLiteral("192.168.0.3")};
    quint16 dataPort = kDefaultDataPort;
    quint32 sampleRate = 500000;
    quint32 channelMask = kDefaultMask;
    quint32 groupsPerPacket = 30;
    bool fromFlash = false;
    quint32 flashSequence = 0;
    quint16 payloadBytes = 1452;
};

struct ControlResponse {
    bool valid = false;
    Command command = Command::Discover;
    Status status = Status::Timeout;
    quint32 transactionId = 0;
    QByteArray data;
    QHostAddress senderIp;
    quint16 senderPort = 0;
};

struct DeviceSummary {
    quint32 deviceId = 0;
    quint32 firmware = 0;
    quint32 hardware = 0;
    quint32 state = 0;
    QHostAddress localIp;
    QHostAddress netmask;
    quint16 dataPort = 0;
    quint16 controlPort = kControlPort;
    QString mac = QStringLiteral("02:00:00:00:00:01");
};

struct DeviceStatus {
    quint32 state = 0;
    quint32 packetsSent = 0;
    quint32 fifoLevel = 0;
    bool arpValid = false;
    bool flashBusy = false;
    bool flashError = false;
    quint32 flashCode = 0;
    bool adcError = false;
    QHostAddress localIp;
    QHostAddress targetIp;
    quint32 flashSequence = 0;
    quint32 activeCopy = 0;
};

struct DeviceInfo {
    DeviceSummary summary;
    QHostAddress targetIp;
    quint16 targetPort = 0;
    quint16 controlPort = kControlPort;
    quint32 sampleRate = 0;
    quint32 channelMask = 0;
    quint32 groupsPerPacket = 0;
    quint16 payloadBytes = 0;
    bool arpValid = false;
    QString learnedMac;
    quint32 flashSequence = 0;
    bool configFromFlash = false;
    bool flashBusy = false;
    bool flashError = false;
    bool adcError = false;
};

struct FlashInfo {
    quint32 jedec = 0;
    quint32 activeCopy = 0;
    quint32 sequence = 0;
    bool flashError = false;
    quint32 errorCode = 0;
    bool busy = false;
};

QString commandName(Command command);
QString statusName(Status status);
QString stateName(quint32 state);
quint32 ipv4ToWord(const QHostAddress &address);
QHostAddress wordToIpv4(quint32 word);
quint32 enabledChannels(quint32 mask);
quint16 payloadBytes(const DeviceConfig &config);
quint32 expectedPacketsPerSecond(const DeviceConfig &config);
bool isValidConfig(const DeviceConfig &config, QString *error = nullptr);

QByteArray makeRequest(Command command, quint32 transactionId,
                       const QByteArray &payload = {});
QByteArray makeSetConfigPayload(const DeviceConfig &config);
ControlResponse parseResponse(const QByteArray &datagram,
                              const QHostAddress &sender, quint16 senderPort);
bool parseConfig(const QByteArray &data, DeviceConfig *config);
bool parseSummary(const QByteArray &data, DeviceSummary *summary);
bool parseDeviceInfo(const QByteArray &data, DeviceInfo *info);
bool parseStatus(const QByteArray &data, DeviceStatus *status);
bool parseFlashInfo(const QByteArray &data, FlashInfo *info);

} // namespace FpgaProtocol
