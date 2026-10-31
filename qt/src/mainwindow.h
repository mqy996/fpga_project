#pragma once

#include "controlclient.h"
#include "dataworker.h"
#include "protocol.h"

#include <QMainWindow>
#include <QString>
#include <QTimer>

class QCheckBox;
class QCloseEvent;
class QComboBox;
class QLineEdit;
class QLabel;
class QPlainTextEdit;
class QPushButton;
class QSpinBox;
class QTableWidget;
class QListWidget;
class WaveWidget;

class MainWindow final : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow() override;
protected:
    void closeEvent(QCloseEvent *event) override;
private slots:
    void refreshAdapters();
    void startDiscovery();
    void selectedDeviceChanged();
    void readConfig();
    void applyConfig();
    void saveConfig();
    void restoreDefaults();
    void getInfo();
    void getFlashInfo();
    void getStatus();
    void onResponse(const FpgaProtocol::ControlResponse &response);
    void onDiscovery(const FpgaProtocol::ControlResponse &response);
    void onRequestFailed(FpgaProtocol::Command command, const QString &reason);
    void onStatusTimer();
    void updatePayloadPreview();
    void fillTargetFromAdapter();
    void startAcquisition();
    void stopAcquisition();
    void updateMonitor();
    void clearMonitor();
    void waveSelectionChanged();
    void saveDataToggled(bool enabled);
private:
    enum class PendingAction { None, GetConfig, SetConfig, ConfirmOldIp, ConfirmNewIp, Save, Restore, GetInfo, GetStatus, GetFlashInfo, Start, Stop };
    void buildUi();
    void loadSettings();
    void saveSettings();
    void appendLog(const QString &message);
    QHostAddress adapterAddress() const;
    QHostAddress deviceAddress() const;
    void setDeviceAddress(const QHostAddress &address);
    FpgaProtocol::DeviceConfig configFromEditor(bool *ok = nullptr) const;
    void configToEditor(const FpgaProtocol::DeviceConfig &config);
    void updateConfigButtons();
    void updateStatusWidgets(const FpgaProtocol::DeviceStatus &status);
    void send(FpgaProtocol::Command command, const QByteArray &payload = {}, PendingAction action = PendingAction::None,
              const QHostAddress &destination = QHostAddress());
    void requestStatus(bool automatic);
    void beginConfigConfirmation(bool useNewIp);
    void completeConfigConfirmation(const FpgaProtocol::DeviceConfig &config);
    void stopMonitorAfterQuietWindow(const QString &reason);
    void startArmedCsvRecording();
    void showOperationError(const QString &title, const QString &detail);
    QVector<int> selectedWaveChannels() const;

    ControlClient m_control;
    UdpDataWorker m_dataWorker;
    QTimer m_statusTimer;
    QTimer m_monitorTimer;
    PendingAction m_pendingAction = PendingAction::None;
    FpgaProtocol::DeviceConfig m_activeConfig;
    FpgaProtocol::DeviceConfig m_pendingConfig;
    bool m_haveActiveConfig = false;
    bool m_confirming = false;
    int m_confirmAttempts = 0;
    QHostAddress m_oldDeviceIp;
    quint32 m_lastState = 0;
    bool m_automaticStatusRequest = false;
    int m_statusFailureCount = 0;
    bool m_waitingForMonitorOpen = false;
    // True only when the board was already RUN because SW1 was pressed.  In
    // that case "接管监测" must bind the local data port only; it must not
    // send a second START control transaction.
    bool m_attachExistingSession = false;
    bool m_startInProgress = false;
    bool m_stopInProgress = false;
    bool m_monitorSawRun = false;
    bool m_monitorStopScheduled = false;
    int m_runConfirmAttempts = 0;

    QComboBox *m_adapterCombo = nullptr;
    QLineEdit *m_broadcastEdit = nullptr;
    QLineEdit *m_deviceIpEdit = nullptr;
    QTableWidget *m_deviceTable = nullptr;
    QLineEdit *m_localIpEdit = nullptr;
    QLineEdit *m_maskEdit = nullptr;
    QLineEdit *m_targetIpEdit = nullptr;
    QSpinBox *m_dataPortSpin = nullptr;
    QComboBox *m_rateCombo = nullptr;
    QSpinBox *m_groupsSpin = nullptr;
    std::array<QCheckBox *, 24> m_channelChecks {};
    QLabel *m_payloadLabel = nullptr;
    QLabel *m_packetRateLabel = nullptr;
    QLabel *m_statusLine = nullptr;
    QLabel *m_stateLabel = nullptr;
    QLabel *m_arpLabel = nullptr;
    QLabel *m_fifoLabel = nullptr;
    QLabel *m_packetsLabel = nullptr;
    QLabel *m_flashLabel = nullptr;
    QLabel *m_adcLabel = nullptr;
    QPushButton *m_applyButton = nullptr;
    QPushButton *m_saveButton = nullptr;
    QPushButton *m_restoreButton = nullptr;
    QPushButton *m_startAcquisitionButton = nullptr;
    QPushButton *m_stopAcquisitionButton = nullptr;
    QLabel *m_monitorInfo = nullptr;
    QLabel *m_monitorCounters = nullptr;
    QCheckBox *m_saveDataCheck = nullptr;
    QLabel *m_saveDataStatus = nullptr;
    QString m_saveDataPath;
    QTableWidget *m_channelTable = nullptr;
    WaveWidget *m_waveWidget = nullptr;
    QPlainTextEdit *m_log = nullptr;
};
