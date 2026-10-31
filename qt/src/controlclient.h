#pragma once

#include "protocol.h"
#include <QObject>
#include <QUdpSocket>
#include <QTimer>

class ControlClient final : public QObject {
    Q_OBJECT
public:
    explicit ControlClient(QObject *parent = nullptr);
    void setBindAddress(const QHostAddress &address);
    bool isBusy() const { return m_busy; }
    void request(FpgaProtocol::Command command, const QHostAddress &destination,
                 const QByteArray &payload = {}, bool broadcast = false);
    void discover(const QHostAddress &broadcastAddress);

signals:
    void responseReceived(const FpgaProtocol::ControlResponse &response);
    void discoveryReceived(const FpgaProtocol::ControlResponse &response);
    void requestSent(FpgaProtocol::Command command, quint32 transactionId, quint16 localPort,
                     const QHostAddress &destination);
    void requestFailed(FpgaProtocol::Command command, const QString &reason);
    void busyChanged(bool busy);

private slots:
    void readPendingDatagrams();
    void onTimeout();

private:
    bool ensureSocket();
    void transmit();
    void finish();
    QUdpSocket m_socket;
    QTimer m_timer;
    QHostAddress m_bindAddress {QStringLiteral("0.0.0.0")};
    QHostAddress m_destination;
    QByteArray m_packet;
    FpgaProtocol::Command m_command = FpgaProtocol::Command::Discover;
    quint32 m_transactionId = 0;
    bool m_busy = false;
    bool m_discovery = false;
    bool m_discoveredAny = false;
    int m_attempt = 0;
    int m_maxAttempts = 3;
    int m_timeoutMs = 1200;
    quint16 m_localPort = 0;
};
