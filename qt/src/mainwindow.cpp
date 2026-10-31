#include "mainwindow.h"
#include "wavewidget.h"

#include <QAbstractItemView>
#include <QApplication>
#include <QCheckBox>
#include <QCloseEvent>
#include <QComboBox>
#include <QDateTime>
#include <QDockWidget>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QGridLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QHostAddress>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QNetworkAddressEntry>
#include <QNetworkInterface>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSettings>
#include <QSpinBox>
#include <QSignalBlocker>
#include <QSplitter>
#include <QStatusBar>
#include <QTabWidget>
#include <QTableWidget>
#include <QVBoxLayout>

namespace {
QString hexVersion(quint32 value) { return QStringLiteral("0x%1").arg(value, 8, 16, QLatin1Char('0')); }
QString ipText(const QHostAddress &address) { return address.isNull() ? QStringLiteral("-") : address.toString(); }
QString sessionDurationText(quint64 elapsedMilliseconds) {
    const quint64 totalSeconds = elapsedMilliseconds / 1000u;
    const quint64 hours = totalSeconds / 3600u;
    const quint64 minutes = (totalSeconds % 3600u) / 60u;
    const quint64 seconds = totalSeconds % 60u;
    return QStringLiteral("%1:%2:%3")
        .arg(hours, 2, 10, QLatin1Char('0'))
        .arg(minutes, 2, 10, QLatin1Char('0'))
        .arg(seconds, 2, 10, QLatin1Char('0'));
}
bool sameConfig(const FpgaProtocol::DeviceConfig &left, const FpgaProtocol::DeviceConfig &right) {
    return left.localIp == right.localIp && left.netmask == right.netmask && left.targetIp == right.targetIp &&
           left.dataPort == right.dataPort && left.sampleRate == right.sampleRate &&
           left.channelMask == right.channelMask && left.groupsPerPacket == right.groupsPerPacket;
}
QLabel *valueLabel() { auto *label = new QLabel(QStringLiteral("-")); label->setTextInteractionFlags(Qt::TextSelectableByMouse); return label; }
}

MainWindow::MainWindow(QWidget *parent) : QMainWindow(parent) {
    setWindowTitle(QStringLiteral("采集卡控制上位机 V6")); resize(1320, 900);
    buildUi(); loadSettings(); refreshAdapters();
    connect(&m_control, &ControlClient::responseReceived, this, &MainWindow::onResponse);
    connect(&m_control, &ControlClient::discoveryReceived, this, &MainWindow::onDiscovery);
    connect(&m_control, &ControlClient::requestSent, this, [this](FpgaProtocol::Command command, quint32 tid, quint16 port, const QHostAddress &destination) {
        if (command != FpgaProtocol::Command::GetStatus || !m_automaticStatusRequest)
            appendLog(QStringLiteral("发送%1到%2:%3，本地UDP端口=%4，TID=0x%5。").arg(FpgaProtocol::commandName(command), destination.toString()).arg(FpgaProtocol::kControlPort).arg(port).arg(tid, 8, 16, QLatin1Char('0')));
    });
    connect(&m_control, &ControlClient::requestFailed, this, &MainWindow::onRequestFailed);
    connect(&m_dataWorker, &UdpDataWorker::monitorOpened, this, [this](bool ok, const QString &message) {
        appendLog(message);
        if (!ok) {
            m_waitingForMonitorOpen = false;
            m_attachExistingSession = false;
            m_startInProgress = false;
            appendLog(QStringLiteral("本机UDP监测未成功绑定，未向FPGA发送START。"));
        } else if (m_waitingForMonitorOpen) {
            m_waitingForMonitorOpen = false;
            startArmedCsvRecording();
            if (m_attachExistingSession) {
                // SW1 has already started this run.  Sending another START
                // is not needed to receive its data and made a transient
                // control-port timeout incorrectly terminate monitoring.
                m_attachExistingSession = false;
                m_startInProgress = false;
                m_monitorSawRun = true;
                appendLog(QStringLiteral("已接管当前由SW1启动的采集会话，未重复发送START。"));
            } else {
                m_startInProgress = true;
                appendLog(QStringLiteral("本机数据端口已就绪，发送软件START。"));
                send(FpgaProtocol::Command::Start, {}, PendingAction::Start);
            }
        }
        updateConfigButtons();
    }, Qt::QueuedConnection);
    connect(&m_dataWorker, &UdpDataWorker::monitorStopped, this, [this](const QString &message) {
        appendLog(message);
        m_monitorSawRun = false;
        m_monitorStopScheduled = false;
        updateConfigButtons();
    }, Qt::QueuedConnection);
    connect(&m_dataWorker, &UdpDataWorker::csvRecordingFinished, this,
            [this](const QString &filePath, quint64 rowsWritten,
                   quint64 droppedPackets, const QString &errorMessage) {
        m_saveDataPath.clear();
        if (m_saveDataCheck && m_saveDataCheck->isChecked()) {
            const QSignalBlocker blocker(m_saveDataCheck);
            m_saveDataCheck->setChecked(false);
        }
        if (!errorMessage.isEmpty()) {
            m_saveDataStatus->setText(QStringLiteral("未生成最终TXT：%1行；%2包未写入")
                .arg(rowsWritten).arg(droppedPackets));
            appendLog(QStringLiteral("TXT未能提交最终文件：%1；已处理%2行，记录队列丢失%3包。%4")
                .arg(filePath).arg(rowsWritten).arg(droppedPackets).arg(errorMessage));
            QMessageBox::warning(this, QStringLiteral("通道数据保存中断"),
                QStringLiteral("未生成最终TXT文件：%1\n已处理：%2行\n记录队列丢失：%3包\n原因：%4")
                    .arg(filePath).arg(rowsWritten).arg(droppedPackets).arg(errorMessage));
        } else {
            m_saveDataStatus->setText(QStringLiteral("已生成：%1（%2行）")
                .arg(QFileInfo(filePath).fileName()).arg(rowsWritten));
            appendLog(QStringLiteral("TXT保存完成：%1；%2行，记录队列丢失%3包。")
                .arg(filePath).arg(rowsWritten).arg(droppedPackets));
            if (droppedPackets > 0) {
                QMessageBox::warning(this, QStringLiteral("通道数据记录有缺失"),
                    QStringLiteral("TXT已保存到：%1\n成功写入%2行，但记录缓冲队列溢出%3包。请检查磁盘速度和系统负载。")
                        .arg(filePath).arg(rowsWritten).arg(droppedPackets));
            }
        }
        updateConfigButtons();
    }, Qt::QueuedConnection);
    m_statusTimer.setInterval(1000); connect(&m_statusTimer, &QTimer::timeout, this, &MainWindow::onStatusTimer); m_statusTimer.start();
    m_monitorTimer.setInterval(200); connect(&m_monitorTimer, &QTimer::timeout, this, &MainWindow::updateMonitor); m_monitorTimer.start();
    statusBar()->showMessage(QStringLiteral("请先选择电脑网卡并发现设备。"));
}

MainWindow::~MainWindow() { m_dataWorker.stopMonitoring(); m_dataWorker.wait(); }

void MainWindow::buildUi() {
    auto *tabs = new QTabWidget(this); setCentralWidget(tabs);
    auto *devicePage = new QWidget; auto *deviceLayout = new QVBoxLayout(devicePage);
    auto *connection = new QGroupBox(QStringLiteral("电脑网卡与设备发现")); auto *connectionForm = new QGridLayout(connection);
    m_adapterCombo = new QComboBox; m_adapterCombo->setEditable(true); auto *refreshButton = new QPushButton(QStringLiteral("刷新网卡"));
    m_broadcastEdit = new QLineEdit(QStringLiteral("192.168.0.255")); m_deviceIpEdit = new QLineEdit(QStringLiteral("192.168.0.2")); auto *discoverButton = new QPushButton(QStringLiteral("广播发现"));
    connectionForm->addWidget(new QLabel(QStringLiteral("电脑网卡IP：")), 0, 0); connectionForm->addWidget(m_adapterCombo, 0, 1); connectionForm->addWidget(refreshButton, 0, 2);
    connectionForm->addWidget(new QLabel(QStringLiteral("定向广播：")), 1, 0); connectionForm->addWidget(m_broadcastEdit, 1, 1); connectionForm->addWidget(discoverButton, 1, 2);
    connectionForm->addWidget(new QLabel(QStringLiteral("当前设备IP：")), 2, 0); connectionForm->addWidget(m_deviceIpEdit, 2, 1, 1, 2);
    deviceLayout->addWidget(connection);
    m_deviceTable = new QTableWidget(0, 7); m_deviceTable->setHorizontalHeaderLabels({QStringLiteral("DeviceID"), QStringLiteral("固件"), QStringLiteral("硬件"), QStringLiteral("MAC"), QStringLiteral("IP"), QStringLiteral("状态"), QStringLiteral("数据端口")});
    m_deviceTable->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch); m_deviceTable->setSelectionBehavior(QAbstractItemView::SelectRows); m_deviceTable->setEditTriggers(QAbstractItemView::NoEditTriggers); deviceLayout->addWidget(m_deviceTable);
    deviceLayout->addWidget(new QLabel(QStringLiteral("提示：DISCOVER 使用广播，不依赖已知设备IP；从表格选择设备后，配置和状态操作将使用其IP。")));
    tabs->addTab(devicePage, QStringLiteral("设备发现"));
    connect(refreshButton, &QPushButton::clicked, this, &MainWindow::refreshAdapters); connect(discoverButton, &QPushButton::clicked, this, &MainWindow::startDiscovery); connect(m_deviceTable, &QTableWidget::itemSelectionChanged, this, &MainWindow::selectedDeviceChanged);

    auto *configPage = new QWidget; auto *configLayout = new QVBoxLayout(configPage); auto *split = new QSplitter;
    auto *networkBox = new QGroupBox(QStringLiteral("运行配置（SET_CONFIG只在FPGA READY状态有效）")); auto *form = new QFormLayout(networkBox);
    m_localIpEdit = new QLineEdit(QStringLiteral("192.168.0.2")); m_maskEdit = new QLineEdit(QStringLiteral("255.255.255.0")); m_targetIpEdit = new QLineEdit(QStringLiteral("192.168.0.3")); auto *useAdapterButton = new QPushButton(QStringLiteral("使用电脑网卡IP作为目标"));
    m_dataPortSpin = new QSpinBox; m_dataPortSpin->setRange(1, 65535); m_dataPortSpin->setValue(56555);
    m_rateCombo = new QComboBox; m_rateCombo->addItem(QStringLiteral("250 kSPS"), 250000); m_rateCombo->addItem(QStringLiteral("500 kSPS"), 500000); m_rateCombo->addItem(QStringLiteral("1000 kSPS"), 1000000);
    m_rateCombo->setCurrentIndex(1); m_groupsSpin = new QSpinBox; m_groupsSpin->setRange(1, 30); m_groupsSpin->setValue(30); m_payloadLabel = valueLabel(); m_packetRateLabel = valueLabel();
    form->addRow(QStringLiteral("FPGA本机IP："), m_localIpEdit); form->addRow(QStringLiteral("子网掩码："), m_maskEdit); form->addRow(QStringLiteral("目标电脑IP："), m_targetIpEdit); form->addRow(QString(), useAdapterButton);
    form->addRow(QStringLiteral("数据UDP端口："), m_dataPortSpin); form->addRow(QStringLiteral("每通道采样率："), m_rateCombo); form->addRow(QStringLiteral("每包组数："), m_groupsSpin); form->addRow(QStringLiteral("UDP有效载荷："), m_payloadLabel); form->addRow(QStringLiteral("理论UDP包率："), m_packetRateLabel);
    split->addWidget(networkBox);
    auto *channelBox = new QGroupBox(QStringLiteral("UDP发送通道掩码（ADC仍采集全部24通道）")); auto *channelGrid = new QGridLayout(channelBox);
    for (int channel = 0; channel < 24; ++channel) { m_channelChecks[channel] = new QCheckBox(QStringLiteral("CH%1").arg(channel)); m_channelChecks[channel]->setChecked(true); channelGrid->addWidget(m_channelChecks[channel], channel / 6, channel % 6); connect(m_channelChecks[channel], &QCheckBox::toggled, this, &MainWindow::updatePayloadPreview); }
    split->addWidget(channelBox); configLayout->addWidget(split);
    auto *configButtons = new QHBoxLayout; auto *readButton = new QPushButton(QStringLiteral("读取当前配置")); m_applyButton = new QPushButton(QStringLiteral("应用配置")); m_saveButton = new QPushButton(QStringLiteral("保存到Flash")); m_restoreButton = new QPushButton(QStringLiteral("恢复RTL默认值")); auto *infoButton = new QPushButton(QStringLiteral("设备信息")); auto *flashButton = new QPushButton(QStringLiteral("Flash信息")); auto *statusButton = new QPushButton(QStringLiteral("立即读取状态"));
    for (auto *button : {readButton, m_applyButton, m_saveButton, m_restoreButton, infoButton, flashButton, statusButton}) configButtons->addWidget(button); configLayout->addLayout(configButtons);
    auto *statusBox = new QGroupBox(QStringLiteral("设备运行状态")); auto *statusForm = new QFormLayout(statusBox); m_stateLabel = valueLabel(); m_arpLabel = valueLabel(); m_fifoLabel = valueLabel(); m_packetsLabel = valueLabel(); m_flashLabel = valueLabel(); m_adcLabel = valueLabel();
    statusForm->addRow(QStringLiteral("状态机："), m_stateLabel); statusForm->addRow(QStringLiteral("主动ARP："), m_arpLabel); statusForm->addRow(QStringLiteral("FIFO组数："), m_fifoLabel); statusForm->addRow(QStringLiteral("累计UDP包："), m_packetsLabel); statusForm->addRow(QStringLiteral("Flash："), m_flashLabel); statusForm->addRow(QStringLiteral("ADC错误："), m_adcLabel); configLayout->addWidget(statusBox);
    tabs->addTab(configPage, QStringLiteral("配置与状态"));
    connect(useAdapterButton, &QPushButton::clicked, this, &MainWindow::fillTargetFromAdapter); connect(readButton, &QPushButton::clicked, this, &MainWindow::readConfig); connect(m_applyButton, &QPushButton::clicked, this, &MainWindow::applyConfig); connect(m_saveButton, &QPushButton::clicked, this, &MainWindow::saveConfig); connect(m_restoreButton, &QPushButton::clicked, this, &MainWindow::restoreDefaults); connect(infoButton, &QPushButton::clicked, this, &MainWindow::getInfo); connect(flashButton, &QPushButton::clicked, this, &MainWindow::getFlashInfo); connect(statusButton, &QPushButton::clicked, this, &MainWindow::getStatus);
    connect(m_dataPortSpin, qOverload<int>(&QSpinBox::valueChanged), this, &MainWindow::updatePayloadPreview); connect(m_rateCombo, qOverload<int>(&QComboBox::currentIndexChanged), this, &MainWindow::updatePayloadPreview); connect(m_groupsSpin, qOverload<int>(&QSpinBox::valueChanged), this, &MainWindow::updatePayloadPreview);

    auto *monitorPage = new QWidget; auto *monitorLayout = new QVBoxLayout(monitorPage); m_monitorInfo = new QLabel(QStringLiteral("软件“开始采集”会先启动本机UDP监测，再发送START；“停止采集”会在FPGA完成当前帧、清空FIFO并回到READY后自动停止监测。SW1/SW2与软件按钮等效，STOP优先。")); m_monitorInfo->setWordWrap(true); monitorLayout->addWidget(m_monitorInfo);
    auto *monitorButtons = new QHBoxLayout; m_startAcquisitionButton = new QPushButton(QStringLiteral("开始采集")); m_stopAcquisitionButton = new QPushButton(QStringLiteral("停止采集")); auto *clearButton = new QPushButton(QStringLiteral("清零统计")); m_monitorCounters = valueLabel(); monitorButtons->addWidget(m_startAcquisitionButton); monitorButtons->addWidget(m_stopAcquisitionButton); monitorButtons->addWidget(clearButton); monitorButtons->addWidget(m_monitorCounters, 1); monitorLayout->addLayout(monitorButtons);
    auto *saveDataRow = new QHBoxLayout;
    m_saveDataCheck = new QCheckBox(QStringLiteral("保存本次采集数据（24路TXT）"));
    m_saveDataCheck->setToolTip(QStringLiteral("采集开始前勾选并选择路径；不勾选则不保存。最终TXT在采集停止后生成，制表符分列，包含每路码值和电压。"));
    m_saveDataStatus = new QLabel(QStringLiteral("未选择保存"));
    saveDataRow->addWidget(m_saveDataCheck);
    saveDataRow->addWidget(m_saveDataStatus, 1);
    monitorLayout->addLayout(saveDataRow);
    auto *monitorSplit = new QSplitter(Qt::Horizontal);
    m_channelTable = new QTableWidget(24, 13);
    m_channelTable->setHorizontalHeaderLabels({
        QStringLiteral("通道"), QStringLiteral("样本数"),
        QStringLiteral("累计最小(码)"), QStringLiteral("累计最大(码)"),
        QStringLiteral("累计均值(码)"), QStringLiteral("累计均值(V)"),
        QStringLiteral("实时电压(V)"),
        QStringLiteral("近10分最小(码)"), QStringLiteral("近10分最小(V)"),
        QStringLiteral("近10分最大(码)"), QStringLiteral("近10分最大(V)"),
        QStringLiteral("近10分峰峰(码)"), QStringLiteral("近10分峰峰(V)")
    });
    m_channelTable->horizontalHeader()->setSectionResizeMode(QHeaderView::ResizeToContents);
    m_channelTable->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    m_channelTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
    for (int channel = 0; channel < 24; ++channel) {
        m_channelTable->setItem(channel, 0, new QTableWidgetItem(QStringLiteral("CH%1").arg(channel, 2, 10, QLatin1Char('0'))));
        for (int column = 1; column < m_channelTable->columnCount(); ++column)
            m_channelTable->setItem(channel, column, new QTableWidgetItem(QStringLiteral("—")));
    }
    m_waveWidget = new WaveWidget(this);
    monitorSplit->addWidget(m_channelTable);
    monitorSplit->addWidget(m_waveWidget);
    monitorSplit->setStretchFactor(0, 0);
    monitorSplit->setStretchFactor(1, 1);
    monitorSplit->setSizes({570, 730});
    monitorLayout->addWidget(monitorSplit, 1);
    tabs->addTab(monitorPage, QStringLiteral("实时监测"));
    connect(m_startAcquisitionButton, &QPushButton::clicked, this, &MainWindow::startAcquisition);
    connect(m_stopAcquisitionButton, &QPushButton::clicked, this, &MainWindow::stopAcquisition);
    connect(m_saveDataCheck, &QCheckBox::toggled, this, &MainWindow::saveDataToggled);
    connect(clearButton, &QPushButton::clicked, this, &MainWindow::clearMonitor);
    connect(m_waveWidget, &WaveWidget::waveSelectionChanged, this, &MainWindow::waveSelectionChanged);
    connect(m_waveWidget, &WaveWidget::waveWindowChanged, this, [this](int milliseconds) {
        if (m_dataWorker.isMonitoring()) m_dataWorker.setWaveWindowMilliseconds(milliseconds);
    });
    connect(m_waveWidget, &WaveWidget::waveViewAnchorChanged, this, [this](quint64 endGroupIndex) {
        if (m_dataWorker.isMonitoring()) m_dataWorker.setWaveViewAnchor(endGroupIndex);
    });
    connect(m_waveWidget, &WaveWidget::waveFollowLatestRequested, this, [this] {
        if (m_dataWorker.isMonitoring()) m_dataWorker.followWaveLatest();
    });

    auto *dock = new QDockWidget(QStringLiteral("操作日志"), this); m_log = new QPlainTextEdit; m_log->setReadOnly(true); dock->setWidget(m_log); addDockWidget(Qt::BottomDockWidgetArea, dock);
    m_statusLine = new QLabel; statusBar()->addPermanentWidget(m_statusLine, 1); updatePayloadPreview(); updateConfigButtons();
}

void MainWindow::loadSettings() { QSettings s; m_adapterCombo->setEditText(s.value(QStringLiteral("adapter"), QStringLiteral("192.168.0.3")).toString()); m_broadcastEdit->setText(s.value(QStringLiteral("broadcast"), QStringLiteral("192.168.0.255")).toString()); m_deviceIpEdit->setText(s.value(QStringLiteral("deviceIp"), QStringLiteral("192.168.0.2")).toString()); }
void MainWindow::saveSettings() { QSettings s; s.setValue(QStringLiteral("adapter"), m_adapterCombo->currentText()); s.setValue(QStringLiteral("broadcast"), m_broadcastEdit->text()); s.setValue(QStringLiteral("deviceIp"), m_deviceIpEdit->text()); }
void MainWindow::closeEvent(QCloseEvent *event) { saveSettings(); m_dataWorker.stopMonitoring(); m_dataWorker.wait(); event->accept(); }

void MainWindow::appendLog(const QString &message) { m_log->appendPlainText(QStringLiteral("[%1] %2").arg(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz")), message)); }
QHostAddress MainWindow::adapterAddress() const { return QHostAddress(m_adapterCombo->currentText().trimmed()); }
QHostAddress MainWindow::deviceAddress() const { return QHostAddress(m_deviceIpEdit->text().trimmed()); }
void MainWindow::setDeviceAddress(const QHostAddress &address) { if (!address.isNull()) m_deviceIpEdit->setText(address.toString()); }

void MainWindow::refreshAdapters() {
    const QString selected = m_adapterCombo->currentText(); m_adapterCombo->clear();
    for (const auto &iface : QNetworkInterface::allInterfaces()) if (iface.flags().testFlag(QNetworkInterface::IsUp) && !iface.flags().testFlag(QNetworkInterface::IsLoopBack)) for (const auto &entry : iface.addressEntries()) if (entry.ip().protocol() == QAbstractSocket::IPv4Protocol) {
        const QString label = entry.ip().toString(); m_adapterCombo->addItem(label, entry.broadcast().toString());
    }
    const int index = m_adapterCombo->findText(selected); if (index >= 0) m_adapterCombo->setCurrentIndex(index); else m_adapterCombo->setEditText(selected);
}

void MainWindow::startDiscovery() { m_deviceTable->setRowCount(0); m_control.setBindAddress(adapterAddress()); appendLog(QStringLiteral("发送DISCOVER到%1:%2。").arg(m_broadcastEdit->text()).arg(FpgaProtocol::kControlPort)); m_control.discover(QHostAddress(m_broadcastEdit->text().trimmed())); }
void MainWindow::selectedDeviceChanged() { const int row = m_deviceTable->currentRow(); if (row >= 0) setDeviceAddress(QHostAddress(m_deviceTable->item(row, 4)->text())); }

FpgaProtocol::DeviceConfig MainWindow::configFromEditor(bool *ok) const {
    FpgaProtocol::DeviceConfig config; config.localIp = QHostAddress(m_localIpEdit->text().trimmed()); config.netmask = QHostAddress(m_maskEdit->text().trimmed()); config.targetIp = QHostAddress(m_targetIpEdit->text().trimmed()); config.dataPort = quint16(m_dataPortSpin->value()); config.sampleRate = m_rateCombo->currentData().toUInt(); config.groupsPerPacket = quint32(m_groupsSpin->value()); config.channelMask = 0;
    for (int channel = 0; channel < 24; ++channel) if (m_channelChecks[channel]->isChecked()) config.channelMask |= 1u << channel;
    config.payloadBytes = FpgaProtocol::payloadBytes(config); QString error; const bool valid = FpgaProtocol::isValidConfig(config, &error); if (ok) *ok = valid; return config;
}

void MainWindow::configToEditor(const FpgaProtocol::DeviceConfig &config) {
    m_localIpEdit->setText(config.localIp.toString()); m_maskEdit->setText(config.netmask.toString()); m_targetIpEdit->setText(config.targetIp.toString()); m_dataPortSpin->setValue(config.dataPort);
    const int rateIndex = m_rateCombo->findData(config.sampleRate); if (rateIndex >= 0) m_rateCombo->setCurrentIndex(rateIndex); m_groupsSpin->setValue(int(config.groupsPerPacket));
    for (int channel = 0; channel < 24; ++channel) m_channelChecks[channel]->setChecked((config.channelMask >> channel) & 1u); updatePayloadPreview();
}

void MainWindow::updatePayloadPreview() { bool ok = false; const auto config = configFromEditor(&ok); m_payloadLabel->setText(ok ? QStringLiteral("%1 字节，启用%2路").arg(FpgaProtocol::payloadBytes(config)).arg(FpgaProtocol::enabledChannels(config.channelMask)) : QStringLiteral("配置无效")); m_packetRateLabel->setText(ok ? QStringLiteral("约 %1 包/秒").arg(FpgaProtocol::expectedPacketsPerSecond(config)) : QStringLiteral("-")); }
void MainWindow::fillTargetFromAdapter() { if (!adapterAddress().isNull()) m_targetIpEdit->setText(adapterAddress().toString()); }

void MainWindow::send(FpgaProtocol::Command command, const QByteArray &payload, PendingAction action, const QHostAddress &destination) {
    const QHostAddress target = destination.isNull() ? deviceAddress() : destination; if (target.isNull()) { showOperationError(QStringLiteral("地址错误"), QStringLiteral("请填写有效的设备IP。")); return; }
    m_pendingAction = action; m_control.setBindAddress(adapterAddress()); m_control.request(command, target, payload); updateConfigButtons();
}
void MainWindow::readConfig() { send(FpgaProtocol::Command::GetConfig, {}, PendingAction::GetConfig); }
void MainWindow::applyConfig() { bool valid = false; const auto config = configFromEditor(&valid); if (!valid) { showOperationError(QStringLiteral("配置错误"), QStringLiteral("请检查IP、掩码、采样率、通道掩码和每包组数。")); return; } if (m_dataWorker.isMonitoring()) { m_dataWorker.stopMonitoring(); appendLog(QStringLiteral("应用配置前已停止数据监测。")); }
    m_pendingConfig = config; m_oldDeviceIp = deviceAddress(); send(FpgaProtocol::Command::SetConfig, FpgaProtocol::makeSetConfigPayload(config), PendingAction::SetConfig); }
void MainWindow::saveConfig() { send(FpgaProtocol::Command::SaveConfig, {}, PendingAction::Save); }
void MainWindow::restoreDefaults() { if (QMessageBox::question(this, QStringLiteral("恢复默认配置"), QStringLiteral("恢复RTL默认配置不会自动写入Flash。是否继续？")) == QMessageBox::Yes) { m_pendingConfig = {}; m_pendingConfig.localIp = QHostAddress(QStringLiteral("192.168.0.2")); m_pendingConfig.netmask = QHostAddress(QStringLiteral("255.255.255.0")); m_pendingConfig.targetIp = QHostAddress(QStringLiteral("192.168.0.3")); m_pendingConfig.dataPort = 56555; m_pendingConfig.sampleRate = 500000; m_pendingConfig.channelMask = 0x00ffffff; m_pendingConfig.groupsPerPacket = 30; m_oldDeviceIp = deviceAddress(); send(FpgaProtocol::Command::RestoreDefault, {}, PendingAction::Restore); } }
void MainWindow::getInfo() { send(FpgaProtocol::Command::GetInfo, {}, PendingAction::GetInfo); }
void MainWindow::getFlashInfo() { send(FpgaProtocol::Command::GetFlashInfo, {}, PendingAction::GetFlashInfo); }
void MainWindow::getStatus() { requestStatus(false); }
void MainWindow::requestStatus(bool automatic) {
    if (m_control.isBusy()) return;
    m_automaticStatusRequest = automatic;
    send(FpgaProtocol::Command::GetStatus, {}, PendingAction::GetStatus);
}

void MainWindow::onDiscovery(const FpgaProtocol::ControlResponse &response) {
    FpgaProtocol::DeviceSummary summary; if (response.status != FpgaProtocol::Status::Ok || !FpgaProtocol::parseSummary(response.data, &summary)) return;
    const int row = m_deviceTable->rowCount(); m_deviceTable->insertRow(row);
    const QStringList values = {QString::number(summary.deviceId), hexVersion(summary.firmware), hexVersion(summary.hardware), summary.mac, summary.localIp.toString(), FpgaProtocol::stateName(summary.state), QString::number(summary.dataPort)};
    for (int column = 0; column < values.size(); ++column) m_deviceTable->setItem(row, column, new QTableWidgetItem(values[column]));
    appendLog(QStringLiteral("发现设备%1：%2").arg(summary.deviceId).arg(summary.localIp.toString()));
}

void MainWindow::beginConfigConfirmation(bool useNewIp) {
    if (++m_confirmAttempts > 4) { m_confirming = false; showOperationError(QStringLiteral("配置确认失败"), QStringLiteral("设备已响应SET_CONFIG，但未能读取到新配置。请使用广播发现重新定位设备。")); return; }
    const QHostAddress route = useNewIp ? m_pendingConfig.localIp : m_oldDeviceIp; m_pendingAction = useNewIp ? PendingAction::ConfirmNewIp : PendingAction::ConfirmOldIp; m_control.setBindAddress(adapterAddress()); m_control.request(FpgaProtocol::Command::GetConfig, route); appendLog(QStringLiteral("确认已应用配置：尝试读取%1。").arg(route.toString()));
}
void MainWindow::completeConfigConfirmation(const FpgaProtocol::DeviceConfig &config) { m_confirming = false; m_activeConfig = config; m_haveActiveConfig = true; configToEditor(config); setDeviceAddress(config.localIp); appendLog(QStringLiteral("配置已确认生效：%1，%2 kSPS，%3组/包。").arg(config.localIp.toString()).arg(config.sampleRate / 1000).arg(config.groupsPerPacket)); updateConfigButtons(); }

void MainWindow::onResponse(const FpgaProtocol::ControlResponse &response) {
    const PendingAction action = m_pendingAction; m_pendingAction = PendingAction::None;
    m_automaticStatusRequest = false;
    if (response.status != FpgaProtocol::Status::Ok) {
        appendLog(QStringLiteral("%1 返回 %2。").arg(FpgaProtocol::commandName(response.command), FpgaProtocol::statusName(response.status)));
        if (action == PendingAction::Start) {
            m_startInProgress = false;
            // A non-OK reply is authoritative: this is unlike a timeout,
            // where the command may already have reached the FPGA.
            if (m_dataWorker.isMonitoring()) m_dataWorker.stopMonitoring();
            showOperationError(QStringLiteral("启动采集失败"), FpgaProtocol::statusName(response.status));
        } else if (action == PendingAction::Stop) {
            m_stopInProgress = false;
            showOperationError(QStringLiteral("停止采集失败"), FpgaProtocol::statusName(response.status));
        }
        updateConfigButtons(); return;
    }
    if (response.command == FpgaProtocol::Command::GetConfig) {
        FpgaProtocol::DeviceConfig config; if (!FpgaProtocol::parseConfig(response.data, &config)) { showOperationError(QStringLiteral("协议错误"), QStringLiteral("GET_CONFIG响应长度或字段无效。")); return; }
        if (action == PendingAction::ConfirmOldIp || action == PendingAction::ConfirmNewIp) {
            if (sameConfig(config, m_pendingConfig)) completeConfigConfirmation(config);
            else beginConfigConfirmation(action == PendingAction::ConfirmOldIp);
        } else { m_activeConfig = config; m_haveActiveConfig = true; configToEditor(config); appendLog(QStringLiteral("读取配置完成，来源：%1，Sequence=%2。").arg(config.fromFlash ? QStringLiteral("Flash") : QStringLiteral("默认/运行时")).arg(config.flashSequence)); }
    } else if (response.command == FpgaProtocol::Command::SetConfig || response.command == FpgaProtocol::Command::RestoreDefault) {
        appendLog(QStringLiteral("%1已确认接收；等待FPGA在帧边界应用新参数。").arg(FpgaProtocol::commandName(response.command))); m_confirming = true; m_confirmAttempts = 0; QTimer::singleShot(500, this, [this] { beginConfigConfirmation(false); });
    } else if (response.command == FpgaProtocol::Command::SaveConfig) { appendLog(QStringLiteral("Flash参数保存成功。")); QTimer::singleShot(200, this, &MainWindow::getFlashInfo); }
    else if (response.command == FpgaProtocol::Command::Start) {
        appendLog(QStringLiteral("软件START已由FPGA执行，等待状态确认RUN。"));
        m_runConfirmAttempts = 0;
        QTimer::singleShot(120, this, [this] { requestStatus(false); });
    }
    else if (response.command == FpgaProtocol::Command::Stop) {
        appendLog(QStringLiteral("软件STOP已由FPGA执行；继续接收直至READY与短暂静默。"));
        m_stopInProgress = true;
        QTimer::singleShot(120, this, [this] { requestStatus(false); });
    }
    else if (response.command == FpgaProtocol::Command::GetStatus) {
        m_statusFailureCount = 0;
        const int normalInterval = m_dataWorker.isMonitoring() ? 3000 : 1000;
        if (m_statusTimer.interval() != normalInterval) m_statusTimer.setInterval(normalInterval);
        FpgaProtocol::DeviceStatus status; if (FpgaProtocol::parseStatus(response.data, &status)) updateStatusWidgets(status);
    }
    else if (response.command == FpgaProtocol::Command::GetFlashInfo) { FpgaProtocol::FlashInfo info; if (FpgaProtocol::parseFlashInfo(response.data, &info)) appendLog(QStringLiteral("Flash：JEDEC=0x%1，副本=%2，Sequence=%3，错误=%4，忙=%5。").arg(info.jedec, 6, 16, QLatin1Char('0')).arg(info.activeCopy).arg(info.sequence).arg(info.flashError).arg(info.busy)); }
    else if (response.command == FpgaProtocol::Command::GetInfo) {
        FpgaProtocol::DeviceInfo info;
        if (!FpgaProtocol::parseDeviceInfo(response.data, &info)) { showOperationError(QStringLiteral("协议错误"), QStringLiteral("GET_INFO响应长度或字段无效。")); }
        else {
            const QString detail = QStringLiteral("DeviceID：%1\n固件：%2\n硬件：%3\n状态：%4\nFPGA IP：%5\n目标IP：%6:%7\n采样率：%8 SPS\n通道掩码：0x%9\n每包组数：%10\nUDP载荷：%11字节\nARP：%12（%13）\n参数来源：%14，Sequence=%15\nFlash：%16，ADC：%17")
                .arg(info.summary.deviceId).arg(hexVersion(info.summary.firmware)).arg(hexVersion(info.summary.hardware)).arg(FpgaProtocol::stateName(info.summary.state)).arg(info.summary.localIp.toString()).arg(info.targetIp.toString()).arg(info.targetPort).arg(info.sampleRate).arg(info.channelMask, 8, 16, QLatin1Char('0')).arg(info.groupsPerPacket).arg(info.payloadBytes).arg(info.arpValid ? QStringLiteral("有效") : QStringLiteral("等待")).arg(info.learnedMac).arg(info.configFromFlash ? QStringLiteral("Flash") : QStringLiteral("默认/运行时")).arg(info.flashSequence).arg(info.flashError ? QStringLiteral("错误") : info.flashBusy ? QStringLiteral("忙") : QStringLiteral("正常")).arg(info.adcError ? QStringLiteral("错误") : QStringLiteral("正常"));
            appendLog(QStringLiteral("GET_INFO完成。"));
            // This modal dialog runs a nested Qt event loop.  Suspend the
            // periodic status query while it is visible so an automatic
            // GET_STATUS cannot re-enter the control transaction/UI handler
            // immediately after GET_INFO.
            const bool statusTimerWasActive = m_statusTimer.isActive();
            m_statusTimer.stop();
            QMessageBox::information(this, QStringLiteral("设备信息"), detail);
            if (statusTimerWasActive) {
                m_statusTimer.setInterval(m_dataWorker.isMonitoring() ? 3000 : 1000);
                m_statusTimer.start();
            }
        }
    }
    updateConfigButtons();
}

void MainWindow::onRequestFailed(FpgaProtocol::Command command, const QString &reason) {
    if (m_pendingAction == PendingAction::ConfirmOldIp) { beginConfigConfirmation(true); return; }
    if (m_pendingAction == PendingAction::ConfirmNewIp) { m_confirming = false; appendLog(QStringLiteral("新IP确认失败；请使用广播发现：%1").arg(reason)); updateConfigButtons(); return; }
    const PendingAction action = m_pendingAction;
    const bool automaticStatusFailure = command == FpgaProtocol::Command::GetStatus && action == PendingAction::GetStatus && m_automaticStatusRequest;
    m_pendingAction = PendingAction::None;
    if (automaticStatusFailure) {
        ++m_statusFailureCount;
        const int backoffMs = m_statusFailureCount == 1 ? 5000 : m_statusFailureCount == 2 ? 15000 : 30000;
        m_statusTimer.setInterval(backoffMs);
        appendLog(QStringLiteral("自动GET_STATUS失败（第%1次）；%2 ms后重试：%3").arg(m_statusFailureCount).arg(backoffMs).arg(reason));
    } else {
        appendLog(QStringLiteral("%1失败：%2").arg(FpgaProtocol::commandName(command), reason));
        if (action == PendingAction::Start) {
            m_startInProgress = false;
            // UDP control is deliberately best-effort at this point: the
            // FPGA may have accepted START and begun data transmission before
            // its response is lost.  Never discard a valid data session just
            // because the response timed out.  The next status response or
            // incoming data will establish RUN; SW2 remains a safe fallback.
            appendLog(QStringLiteral("START响应超时；保留本机UDP监测，因为FPGA可能已进入RUN。将继续观察数据与状态。"));
        } else if (action == PendingAction::Stop) {
            m_stopInProgress = false;
            appendLog(QStringLiteral("STOP响应超时；继续保持UDP监测。若数据仍在发送，请按SW2停止。"));
        }
    }
    m_automaticStatusRequest = false; updateConfigButtons();
}

void MainWindow::onStatusTimer() {
    if (m_control.isBusy() || deviceAddress().isNull()) return;
    if (m_statusFailureCount == 0) {
        const int interval = m_dataWorker.isMonitoring() ? 3000 : 1000;
        if (m_statusTimer.interval() != interval) m_statusTimer.setInterval(interval);
    }
    requestStatus(true);
}
void MainWindow::updateStatusWidgets(const FpgaProtocol::DeviceStatus &status) {
    m_lastState = status.state;
    m_stateLabel->setText(FpgaProtocol::stateName(status.state)); m_arpLabel->setText(status.arpValid ? QStringLiteral("有效") : QStringLiteral("未完成")); m_fifoLabel->setText(QString::number(status.fifoLevel)); m_packetsLabel->setText(QString::number(status.packetsSent)); m_flashLabel->setText(status.flashError ? QStringLiteral("错误码%1").arg(status.flashCode) : status.flashBusy ? QStringLiteral("忙") : QStringLiteral("正常")); m_adcLabel->setText(status.adcError ? QStringLiteral("ADC错误") : QStringLiteral("正常")); m_statusLine->setText(QStringLiteral("%1 | ARP:%2 | FIFO:%3").arg(FpgaProtocol::stateName(status.state)).arg(status.arpValid ? QStringLiteral("OK") : QStringLiteral("等待")).arg(status.fifoLevel));
    if (status.state == 4) {
        if (!m_monitorSawRun && m_dataWorker.isMonitoring()) appendLog(QStringLiteral("FPGA已进入RUN，正在接收数据UDP。"));
        m_monitorSawRun = m_monitorSawRun || m_dataWorker.isMonitoring();
        if (m_startInProgress) { m_startInProgress = false; appendLog(QStringLiteral("软件START状态确认：FPGA处于RUN。")); }
    }
    if (status.state == 3) {
        if (m_stopInProgress) appendLog(QStringLiteral("软件STOP状态确认：FPGA已回到READY。"));
        if ((m_stopInProgress || m_monitorSawRun) && m_dataWorker.isMonitoring()) stopMonitorAfterQuietWindow(QStringLiteral("FPGA已回到READY，UDP静默窗口结束后自动停止监测。"));
        m_stopInProgress = false;
    }
    if (m_startInProgress && status.state != 4) {
        if (++m_runConfirmAttempts < 10) QTimer::singleShot(150, this, [this] { requestStatus(false); });
        else { m_startInProgress = false; if (m_dataWorker.isMonitoring()) m_dataWorker.stopMonitoring(); showOperationError(QStringLiteral("启动采集失败"), QStringLiteral("START已响应，但未在限定时间内进入RUN。")); }
    }
    updateConfigButtons();
}

void MainWindow::updateConfigButtons() {
    const bool ready = m_lastState == 3;
    const bool running = m_lastState == 4;
    const bool stopping = m_lastState == 5;
    const bool idleControl = !m_control.isBusy() && !m_confirming && !m_startInProgress && !m_stopInProgress;
    const bool allow = ready && !m_dataWorker.isMonitoring() && idleControl;
    m_applyButton->setEnabled(allow); m_saveButton->setEnabled(allow); m_restoreButton->setEnabled(allow);
    if (m_startAcquisitionButton) {
        m_startAcquisitionButton->setEnabled(idleControl && (ready || (running && !m_dataWorker.isMonitoring())));
        m_startAcquisitionButton->setText(running && !m_dataWorker.isMonitoring() ? QStringLiteral("接管监测") : QStringLiteral("开始采集"));
    }
    // If a START response was lost, the last confirmed state can still be
    // READY while data is already arriving.  Keep STOP available in that
    // ambiguous-but-active local monitoring case.
    if (m_stopAcquisitionButton)
        m_stopAcquisitionButton->setEnabled(idleControl && !stopping &&
                                             (running || m_dataWorker.isMonitoring()));
    if (m_saveDataCheck) {
        const bool recorderBusy = m_dataWorker.isCsvRecorderBusy();
        const bool allChannelsEnabled = m_haveActiveConfig &&
            m_activeConfig.channelMask == 0x00ffffffu;
        if (m_saveDataCheck->isChecked() && !allChannelsEnabled && !recorderBusy) {
            const QSignalBlocker blocker(m_saveDataCheck);
            m_saveDataCheck->setChecked(false);
            m_saveDataPath.clear();
            m_saveDataStatus->setText(QStringLiteral("配置未启用全部24路，已取消保存"));
            appendLog(QStringLiteral("当前生效配置不是全部24路，已取消本次TXT保存选项。"));
        }
        const bool canArm = ready && idleControl && allChannelsEnabled &&
            !m_dataWorker.isMonitoring() && !m_waitingForMonitorOpen &&
            !m_startInProgress && !m_stopInProgress && !recorderBusy;
        m_saveDataCheck->setEnabled(canArm);
    }
}
void MainWindow::showOperationError(const QString &title, const QString &detail) { appendLog(title + QStringLiteral("：") + detail); QMessageBox::warning(this, title, detail); }

QVector<int> MainWindow::selectedWaveChannels() const {
    return m_waveWidget ? m_waveWidget->selectedChannels() : QVector<int>();
}

void MainWindow::waveSelectionChanged() {
    if (m_dataWorker.isMonitoring())
        m_dataWorker.setWaveChannels(selectedWaveChannels());
}

void MainWindow::saveDataToggled(bool enabled) {
    if (!enabled) {
        if (m_dataWorker.isCsvRecorderBusy()) {
            const QSignalBlocker blocker(m_saveDataCheck);
            m_saveDataCheck->setChecked(true);
            return;
        }
        m_saveDataPath.clear();
        m_saveDataStatus->setText(QStringLiteral("本次不保存"));
        appendLog(QStringLiteral("已取消本次采集的数据保存选项。"));
        updateConfigButtons();
        return;
    }

    if (m_lastState != 3 || !m_haveActiveConfig ||
        m_activeConfig.channelMask != 0x00ffffffu || m_dataWorker.isMonitoring() ||
        m_waitingForMonitorOpen || m_startInProgress || m_stopInProgress ||
        m_dataWorker.isCsvRecorderBusy()) {
        {
            const QSignalBlocker blocker(m_saveDataCheck);
            m_saveDataCheck->setChecked(false);
        }
        showOperationError(QStringLiteral("当前不能设置数据保存"),
            QStringLiteral("请在FPGA处于READY且当前配置启用全部24路时，采集开始前选择保存。"));
        updateConfigButtons();
        return;
    }

    QString path = QFileDialog::getSaveFileName(this, QStringLiteral("保存24路通道码值和电压"),
        QDir::home().filePath(QStringLiteral("adc_channels_%1.txt")
            .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss")))),
        QStringLiteral("文本文件 (*.txt)"));
    if (path.isEmpty()) {
        const QSignalBlocker blocker(m_saveDataCheck);
        m_saveDataCheck->setChecked(false);
        m_saveDataStatus->setText(QStringLiteral("未选择保存"));
        return;
    }
    const QFileInfo selectedFile(path);
    if (selectedFile.suffix().compare(QStringLiteral("txt"), Qt::CaseInsensitive) != 0)
        path = QDir(selectedFile.path()).filePath(selectedFile.completeBaseName() + QStringLiteral(".txt"));
    m_saveDataPath = path;
    m_saveDataStatus->setText(QStringLiteral("已选择：%1；停止后生成TXT")
        .arg(QFileInfo(path).fileName()));
    appendLog(QStringLiteral("已为下一次采集选择TXT路径：%1。每路同时记录原始码值和电压；采集停止后才生成最终文件。")
        .arg(path));
    updateConfigButtons();
}

void MainWindow::startArmedCsvRecording() {
    if (!m_saveDataCheck || !m_saveDataCheck->isChecked() || m_saveDataPath.isEmpty())
        return;

    QString error;
    if (!m_dataWorker.startCsvRecording(m_saveDataPath, &error)) {
        const QSignalBlocker blocker(m_saveDataCheck);
        m_saveDataCheck->setChecked(false);
        const QString path = m_saveDataPath;
        m_saveDataPath.clear();
        m_saveDataStatus->setText(QStringLiteral("未启动保存"));
        appendLog(QStringLiteral("TXT记录未能启动，本次采集继续但不会保存。%1").arg(error));
        QMessageBox::warning(this, QStringLiteral("通道数据保存未启动"),
            QStringLiteral("本次采集会继续，但不会保存TXT。\n路径：%1\n原因：%2")
                .arg(path, error));
        return;
    }

    m_saveDataStatus->setText(QStringLiteral("记录中；停止后生成：%1")
        .arg(QFileInfo(m_saveDataPath).fileName()));
    appendLog(QStringLiteral("已启动24路TXT记录：%1。每路包含码值与电压，最终文件将在采集停止后生成。")
        .arg(m_saveDataPath));
}

void MainWindow::startAcquisition() {
    if (!m_haveActiveConfig) { showOperationError(QStringLiteral("尚无配置"), QStringLiteral("请先读取当前配置或成功应用配置。")); return; }
    if (adapterAddress().isNull() || deviceAddress().isNull()) { showOperationError(QStringLiteral("地址错误"), QStringLiteral("请先选择有效的电脑网卡IP和设备IP。")); return; }
    if (m_lastState != 3 && !(m_lastState == 4 && !m_dataWorker.isMonitoring())) {
        showOperationError(QStringLiteral("当前状态不可启动"), QStringLiteral("仅在READY启动；若SW1已使板卡RUN，可用“接管监测”绑定本机UDP接收。")); return;
    }
    if (m_dataWorker.isMonitoring()) {
        showOperationError(QStringLiteral("监测已运行"), QStringLiteral("本机UDP监测已启动。请使用“停止采集”或SW2结束会话。")); return;
    }
    m_monitorSawRun = false;
    m_attachExistingSession = (m_lastState == 4);
    m_waitingForMonitorOpen = true;
    m_startInProgress = true;
    if (!m_dataWorker.startMonitoring(m_activeConfig, adapterAddress(), deviceAddress(), selectedWaveChannels(),
                                      m_waveWidget->windowMilliseconds())) {
        m_waitingForMonitorOpen = false; m_startInProgress = false;
        showOperationError(QStringLiteral("监测启动失败"), QStringLiteral("无法创建本机UDP接收线程。"));
        updateConfigButtons();
        return;
    }
    appendLog(m_attachExistingSession ? QStringLiteral("正在接管已由SW1启动的采集会话。") : QStringLiteral("正在启动本机UDP监测，随后发送软件START。"));
    updateConfigButtons();
}

void MainWindow::stopAcquisition() {
    if (m_lastState != 4 && !m_dataWorker.isMonitoring()) { showOperationError(QStringLiteral("当前状态不可停止"), QStringLiteral("FPGA不在RUN，且本机未监测到活动会话。")); return; }
    if (m_control.isBusy()) { showOperationError(QStringLiteral("控制忙"), QStringLiteral("请等待当前控制命令完成后再停止。")); return; }
    m_stopInProgress = true;
    appendLog(QStringLiteral("发送软件STOP；本机UDP监测将在FPGA回到READY后自动关闭。"));
    send(FpgaProtocol::Command::Stop, {}, PendingAction::Stop);
}

void MainWindow::stopMonitorAfterQuietWindow(const QString &reason) {
    if (m_monitorStopScheduled || !m_dataWorker.isMonitoring()) return;
    m_monitorStopScheduled = true;
    appendLog(reason);
    // The FPGA has already reported READY, so no new UDP frame may start.
    // Leave a short receive drain window for the final frame that reached the
    // PC network stack immediately before that status response.
    QTimer::singleShot(300, this, [this] {
        if (m_dataWorker.isMonitoring()) m_dataWorker.stopMonitoring();
    });
}
void MainWindow::clearMonitor() { m_dataWorker.requestClear(); appendLog(QStringLiteral("已请求清零本轮监测统计。")); }
void MainWindow::updateMonitor() {
    const auto snapshot = m_dataWorker.snapshot();
    // Data is stronger evidence than a delayed control status response.
    // This also prevents a START-response timeout from being treated as a
    // reason to close an otherwise healthy UDP stream.
    if (snapshot.receivedPackets > 0 && m_dataWorker.isMonitoring() && !m_monitorSawRun) {
        m_monitorSawRun = true;
        updateConfigButtons();
    }
    const double theoreticalRate = m_activeConfig.groupsPerPacket
        ? double(m_activeConfig.sampleRate) / double(m_activeConfig.groupsPerPacket) : 0.0;
    m_monitorCounters->setText(QStringLiteral("运行时长=%1，接收=%2，处理=%3，近1秒=%4包/s，平均=%5包/s，理论=%6包/s，Seq丢失=%7，重复=%8，乱序=%9，队列=%10/%11，队列溢出=%12，长度错=%13，头错=%14，来源错=%15")
        .arg(sessionDurationText(snapshot.elapsedMs))
        .arg(snapshot.receivedPackets).arg(snapshot.packets)
        .arg(snapshot.recentPacketRate, 0, 'f', 0)
        .arg(snapshot.averagePacketRate, 0, 'f', 1)
        .arg(theoreticalRate, 0, 'f', 2)
        .arg(snapshot.lost).arg(snapshot.duplicates).arg(snapshot.outOfOrder)
        .arg(snapshot.queueDepth).arg(65536)
        .arg(snapshot.queueOverflows).arg(snapshot.lengthErrors).arg(snapshot.headerErrors)
        .arg(snapshot.sourceErrors));
    if (m_dataWorker.isCsvRecording()) {
        m_saveDataStatus->setText(QStringLiteral("记录中：%1行；停止后生成文件；队列溢出%2包")
            .arg(m_dataWorker.csvRowsWritten()).arg(m_dataWorker.csvDroppedPackets()));
    } else if (m_dataWorker.isCsvRecorderBusy()) {
        m_saveDataStatus->setText(QStringLiteral("正在收尾并生成最终TXT：%1行")
            .arg(m_dataWorker.csvRowsWritten()));
    }
    for (int channel = 0; channel < 24; ++channel) {
        const auto &stats = snapshot.channels[channel];
        m_channelTable->item(channel, 1)->setText(QString::number(stats.samples));
        if (!stats.samples) {
            for (int column = 2; column < m_channelTable->columnCount(); ++column)
                m_channelTable->item(channel, column)->setText(QStringLiteral("—"));
            continue;
        }
        m_channelTable->item(channel, 2)->setText(QString::number(stats.minimum));
        m_channelTable->item(channel, 3)->setText(QString::number(stats.maximum));
        m_channelTable->item(channel, 4)->setText(QString::number(stats.mean, 'f', 2));
        m_channelTable->item(channel, 5)->setText(QString::asprintf("%+.4f V",
            (stats.mean * AdcDisplay::kInputRangeVolts) / 32768.0));
        m_channelTable->item(channel, 6)->setText(stats.hasLatest
            ? QString::asprintf("%+.4f V", AdcDisplay::codeToVolts(stats.latest)) : QStringLiteral("—"));
        if (stats.hasRecent) {
            const int recentVppCode = int(stats.recentMaximum) - int(stats.recentMinimum);
            const double recentMinV = AdcDisplay::codeToVolts(stats.recentMinimum);
            const double recentMaxV = AdcDisplay::codeToVolts(stats.recentMaximum);
            m_channelTable->item(channel, 7)->setText(QString::number(stats.recentMinimum));
            m_channelTable->item(channel, 8)->setText(QString::asprintf("%+.4f V", recentMinV));
            m_channelTable->item(channel, 9)->setText(QString::number(stats.recentMaximum));
            m_channelTable->item(channel, 10)->setText(QString::asprintf("%+.4f V", recentMaxV));
            m_channelTable->item(channel, 11)->setText(QString::number(recentVppCode));
            m_channelTable->item(channel, 12)->setText(QString::asprintf("%+.4f V", recentMaxV - recentMinV));
        } else {
            for (int column = 7; column < m_channelTable->columnCount(); ++column)
                m_channelTable->item(channel, column)->setText(QStringLiteral("—"));
        }
    }
    m_waveWidget->setSnapshot(snapshot);
    if (!m_dataWorker.isMonitoring()) updateConfigButtons();
}
