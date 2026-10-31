#pragma once

#include "protocol.h"
#include "adcmath.h"
#include "csvrecorder.h"
#include "waveviewmath.h"

#include <QMutex>
#include <QThread>
#include <QVector>
#include <array>
#include <atomic>
#include <limits>
#include <mutex>
#include <vector>

struct ChannelSnapshot {
    quint64 samples = 0;
    qint16 minimum = 0;
    qint16 maximum = 0;
    double mean = 0.0;
    bool hasLatest = false;
    qint16 latest = 0;
    bool hasRecent = false;
    qint16 recentMinimum = 0;
    qint16 recentMaximum = 0;
};

struct WaveEnvelopePoint {
    bool valid = false;
    qint16 minimum = 0;
    qint16 maximum = 0;
};

struct MonitorSnapshot {
    // packets retains the processed count for compatibility with the table.
    quint64 packets = 0;
    quint64 receivedPackets = 0;
    quint64 lost = 0;
    quint64 duplicates = 0;
    quint64 outOfOrder = 0;
    quint64 lengthErrors = 0;
    quint64 headerErrors = 0;
    quint64 sourceErrors = 0;
    quint64 socketErrors = 0;
    quint64 queueOverflows = 0;
    quint64 queueDepth = 0;
    quint64 receiveBufferBytes = 0;
    quint64 elapsedMs = 0;
    double averagePacketRate = 0.0;
    double recentPacketRate = 0.0;
    int waveWindowMilliseconds = 60 * 1000;
    quint32 waveSampleRate = 0;
    quint64 latestGroupIndex = 0;
    quint64 viewEndGroupIndex = 0;
    bool waveFollowsLatest = true;
    bool waveUsesFineHistory = false;
    std::array<ChannelSnapshot, 24> channels {};
    std::array<bool, 24> waveEnabled {};
    std::array<QVector<WaveEnvelopePoint>, 24> waves {};
    QVector<int> waveChannels;
};

// The QThread itself is the socket receiver.  It never parses ADC samples or
// creates Qt waveform objects.  A private processor thread drains this fixed
// SPSC queue and owns all statistics/history work.
class UdpDataWorker final : public QThread {
    Q_OBJECT
public:
    explicit UdpDataWorker(QObject *parent = nullptr);
    ~UdpDataWorker() override;
    bool startMonitoring(const FpgaProtocol::DeviceConfig &config, const QHostAddress &bindAddress,
                         const QHostAddress &allowedSource, const QVector<int> &waveChannels,
                         int waveWindowMilliseconds = 60 * 1000);
    void stopMonitoring();
    bool isMonitoring() const { return isRunning(); }
    bool isUdpReady() const { return m_udpReady.load(std::memory_order_acquire); }
    void setWaveChannels(const QVector<int> &channels);
    void setWaveChannelEnabled(int channel, bool enabled);
    void setWaveWindowMilliseconds(int milliseconds);
    void setWaveViewAnchor(quint64 endGroupIndex);
    void followWaveLatest();
    void requestClear();
    bool startCsvRecording(const QString &filePath, QString *errorMessage = nullptr);
    void stopCsvRecording();
    bool isCsvRecording() const;
    bool isCsvRecorderBusy() const;
    quint64 csvRowsWritten() const;
    quint64 csvDroppedPackets() const;
    MonitorSnapshot snapshot() const;

signals:
    void monitorOpened(bool ok, const QString &message);
    void monitorStopped(const QString &message);
    void csvRecordingFinished(const QString &filePath, quint64 rowsWritten,
                              quint64 droppedPackets, const QString &errorMessage);

protected:
    void run() override;

private:
    static constexpr int kPacketBytes = 1600;
    static constexpr quint64 kQueueSlots = 65536;

    struct PacketSlot {
        std::array<char, kPacketBytes> bytes {};
        quint16 size = 0;
        quint64 generation = 0;
    };

    class PacketRing final {
    public:
        PacketRing();
        bool push(const char *bytes, quint16 size, quint64 generation);
        bool pop(PacketSlot *slot);
        quint64 depth() const;
        bool empty() const;

    private:
        std::vector<PacketSlot> m_slots;
        alignas(64) std::atomic<quint64> m_head {0};
        alignas(64) std::atomic<quint64> m_tail {0};
    };

    struct Statistics {
        quint64 packets = 0;
        std::array<quint64, 24> count {};
        std::array<qint16, 24> minimum {};
        std::array<qint16, 24> maximum {};
        std::array<qint16, 24> latest {};
        std::array<qint64, 24> sum {};
    };

    struct TimeBucket {
        quint64 index = std::numeric_limits<quint64>::max();
        qint16 minimum = 0;
        qint16 maximum = 0;
    };

    template <int BucketCount>
    struct TimeHistory {
        QVector<TimeBucket> buckets;
        TimeHistory();
        void clear();
        void add(quint64 bucketIndex, qint16 value);
        bool get(quint64 bucketIndex, TimeBucket *bucket) const;
    };

    using CoarseTimeHistory = TimeHistory<AdcDisplay::kMaximumHistoryBuckets>;
    using FineTimeHistory = TimeHistory<AdcDisplay::kFineHistoryBuckets>;

    void resetLocal(Statistics &stats, std::array<CoarseTimeHistory, 24> &history,
                    std::array<FineTimeHistory, 24> &fineHistory,
                    quint64 &latestBucket, quint64 &latestFineBucket,
                    quint64 &latestGroupIndex);
    void processPackets(PacketRing &queue, const std::atomic_bool &receiverFinished,
                        quint64 receiveBufferBytes);
    void publish(const Statistics &stats, const std::array<CoarseTimeHistory, 24> &history,
                 const std::array<FineTimeHistory, 24> &fineHistory,
                 quint64 latestBucket, quint64 latestFineBucket,
                 quint64 latestGroupIndex, quint64 receiveBufferBytes,
                 quint64 queueDepth);
    void resetReceiverCounters();

    mutable QMutex m_mutex;
    std::mutex m_recorderLifecycleMutex;
    CsvRecorder m_csvRecorder;
    FpgaProtocol::DeviceConfig m_config;
    QHostAddress m_bindAddress;
    QHostAddress m_allowedSource;
    std::atomic<quint32> m_waveMask {0};
    int m_waveWindowMilliseconds = 60 * 1000;
    bool m_waveFollowLatest = true;
    quint64 m_waveViewEndGroupIndex = 0;
    MonitorSnapshot m_snapshot;

    std::atomic_bool m_stop {false};
    std::atomic_bool m_udpReady {false};
    std::atomic<quint64> m_generation {1};
    std::atomic<quint64> m_receivedPackets {0};
    std::atomic<quint64> m_receiverLost {0};
    std::atomic<quint64> m_receiverDuplicates {0};
    std::atomic<quint64> m_receiverOutOfOrder {0};
    std::atomic<quint64> m_receiverLengthErrors {0};
    std::atomic<quint64> m_receiverHeaderErrors {0};
    std::atomic<quint64> m_receiverSourceErrors {0};
    std::atomic<quint64> m_receiverSocketErrors {0};
    std::atomic<quint64> m_queueOverflows {0};
    std::atomic<quint64> m_receiverElapsedMs {0};
    std::atomic<double> m_receiverRecentRate {0.0};
};
