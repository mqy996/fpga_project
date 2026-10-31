#include "controlclient.h"

#include <QDateTime>
#include <QRandomGenerator>

ControlClient::ControlClient(QObject *parent) : QObject(parent) {
    connect(&m_socket, &QUdpSocket::readyRead, this, &ControlClient::readPendingDatagrams);
    connect(&m_timer, &QTimer::timeout, this, &ControlClient::onTimeout);
    m_timer.setSingleShot(true);
}

void ControlClient::setBindAddress(const QHostAddress &address) {
    if (m_bindAddress == address) return;
    m_bindAddress = address;
    if (!m_busy) m_socket.close();
}

bool ControlClient::ensureSocket() {
    if (m_socket.state() == QAbstractSocket::BoundState) return true;
    if (!m_socket.bind(m_bindAddress, 0)) return false;
    m_localPort = m_socket.localPort();
    return true;
}

void ControlClient::request(FpgaProtocol::Command command, const QHostAddress &destination,
                            const QByteArray &payload, bool broadcast) {
    if (m_busy) { emit requestFailed(command, QStringLiteral("已有控制请求正在等待响应。")); return; }
    if (!ensureSocket()) { emit requestFailed(command, QStringLiteral("控制套接字绑定失败：%1").arg(m_socket.errorString())); return; }
    m_command = command; m_destination = destination; m_discovery = broadcast; m_discoveredAny = false;
    m_transactionId = QRandomGenerator::global()->generate() ^ quint32(QDateTime::currentMSecsSinceEpoch());
    m_packet = FpgaProtocol::makeRequest(command, m_transactionId, payload);
    m_timeoutMs = command == FpgaProtocol::Command::SaveConfig ? 10000 : 1200;
    m_maxAttempts = command == FpgaProtocol::Command::SaveConfig ? 2 : 3;
    m_attempt = 0; m_busy = true; emit busyChanged(true); transmit();
}

void ControlClient::discover(const QHostAddress &broadcastAddress) { request(FpgaProtocol::Command::Discover, broadcastAddress, {}, true); }

void ControlClient::transmit() {
    ++m_attempt;
    if (m_socket.writeDatagram(m_packet, m_destination, FpgaProtocol::kControlPort) < 0) {
        const auto command = m_command; finish(); emit requestFailed(command, QStringLiteral("发送失败：%1").arg(m_socket.errorString())); return;
    }
    emit requestSent(m_command, m_transactionId, m_localPort, m_destination);
    m_timer.start(m_discovery ? 700 : m_timeoutMs);
}

void ControlClient::finish() {
    m_timer.stop();
    // The verified command-line tool opens one UDP socket per transaction.
    // Do the same here: a stale datagram or an interrupted transaction can
    // never affect the next command's source port or receive queue.
    m_socket.close();
    m_localPort = 0;
    if (m_busy) { m_busy = false; emit busyChanged(false); }
}

void ControlClient::readPendingDatagrams() {
    while (m_socket.hasPendingDatagrams()) {
        QHostAddress sender; quint16 port = 0; QByteArray datagram;
        datagram.resize(int(m_socket.pendingDatagramSize()));
        m_socket.readDatagram(datagram.data(), datagram.size(), &sender, &port);
        const auto response = FpgaProtocol::parseResponse(datagram, sender, port);
        if (!response.valid || response.command != m_command || response.transactionId != m_transactionId) continue;
        if (m_discovery) { m_discoveredAny = true; emit discoveryReceived(response); continue; }
        finish(); emit responseReceived(response); return;
    }
}

void ControlClient::onTimeout() {
    if (!m_busy) return;
    if (m_discovery) { const bool discovered = m_discoveredAny; finish(); if (!discovered) emit requestFailed(m_command, QStringLiteral("未收到设备发现响应。")); return; }
    if (m_attempt < m_maxAttempts) { transmit(); return; }
    const auto command = m_command; const quint16 localPort = m_localPort; const quint32 tid = m_transactionId; finish();
    emit requestFailed(command, QStringLiteral("%1 超时（已按同一TransactionId重试；本地UDP端口=%2，TID=0x%3）。")
                       .arg(FpgaProtocol::commandName(command)).arg(localPort).arg(tid, 8, 16, QLatin1Char('0')));
}
