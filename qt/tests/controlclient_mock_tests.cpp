#include "controlclient.h"

#include <QCoreApplication>
#include <QTimer>
#include <QUdpSocket>
#include <QDebug>

namespace {
quint32 get32(const QByteArray &b, int offset) { return (quint32(quint8(b[offset])) << 24) | (quint32(quint8(b[offset + 1])) << 16) | (quint32(quint8(b[offset + 2])) << 8) | quint32(quint8(b[offset + 3])); }
void put32(QByteArray &b, quint32 value) { b.append(char(value >> 24)); b.append(char(value >> 16)); b.append(char(value >> 8)); b.append(char(value)); }
QByteArray response(quint32 command, quint32 tid) { QByteArray b; put32(b, command | 0x80000000u); put32(b, 0); put32(b, 0); put32(b, tid); return b; }
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QUdpSocket mock;
    if (!mock.bind(QHostAddress::LocalHost, FpgaProtocol::kControlPort)) { qCritical() << "mock bind failed"; return 1; }
    ControlClient client; client.setBindAddress(QHostAddress::LocalHost);
    bool statusOk = false; int discovered = 0; bool failed = false;
    QObject::connect(&mock, &QUdpSocket::readyRead, &app, [&] {
        while (mock.hasPendingDatagrams()) {
            QHostAddress sender; quint16 port = 0; QByteArray request; request.resize(int(mock.pendingDatagramSize())); mock.readDatagram(request.data(), request.size(), &sender, &port);
            const quint32 command = get32(request, 0), tid = get32(request, 12);
            mock.writeDatagram(response(command, tid), sender, port);
            if (command == quint32(FpgaProtocol::Command::Discover)) mock.writeDatagram(response(command, tid), sender, port);
        }
    });
    QObject::connect(&client, &ControlClient::responseReceived, &app, [&](const FpgaProtocol::ControlResponse &reply) {
        if (reply.command != FpgaProtocol::Command::GetStatus || reply.status != FpgaProtocol::Status::Ok) { failed = true; app.quit(); return; }
        statusOk = true; client.discover(QHostAddress::LocalHost);
    });
    QObject::connect(&client, &ControlClient::discoveryReceived, &app, [&](const FpgaProtocol::ControlResponse &) { ++discovered; });
    QObject::connect(&client, &ControlClient::requestFailed, &app, [&](FpgaProtocol::Command, const QString &reason) { qCritical() << reason; failed = true; app.quit(); });
    QTimer::singleShot(0, &app, [&] { client.request(FpgaProtocol::Command::GetStatus, QHostAddress::LocalHost); });
    QTimer::singleShot(1200, &app, [&] { app.quit(); });
    app.exec();
    if (!statusOk || discovered != 2 || failed) { qCritical() << "statusOk=" << statusOk << "discovered=" << discovered << "failed=" << failed; return 1; }
    return 0;
}
