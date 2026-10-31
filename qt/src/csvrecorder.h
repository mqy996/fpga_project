#pragma once

#include <QObject>
#include <QString>
#include <QtGlobal>

#include <array>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

class CsvRecorder final : public QObject {
    Q_OBJECT
public:
    explicit CsvRecorder(QObject *parent = nullptr);
    ~CsvRecorder() override;

    bool start(const QString &filePath, quint32 sampleRate, quint32 groupsPerPacket,
               quint32 channelMask, QString *errorMessage = nullptr);
    void enqueuePacket(const char *bytes, quint16 size);
    void stop();
    void stopAndWait();

    bool isRecording() const;
    bool isBusy() const;
    quint64 rowsWritten() const;
    quint64 droppedPackets() const;

signals:
    void recordingFinished(const QString &filePath, quint64 rowsWritten,
                           quint64 droppedPackets, const QString &errorMessage);

private:
    enum class State : int { Idle, Starting, Recording, Stopping };
    static constexpr quint64 kQueueSlots = 32768;
    static constexpr int kPacketBytes = 1600;

    struct PacketSlot {
        std::array<char, kPacketBytes> bytes {};
        quint16 size = 0;
    };

    bool push(const char *bytes, quint16 size);
    bool pop(PacketSlot *slot);
    quint64 queueDepth() const;
    void run();

    std::vector<PacketSlot> m_slots;
    alignas(64) std::atomic<quint64> m_head {0};
    alignas(64) std::atomic<quint64> m_tail {0};
    std::atomic<State> m_state {State::Idle};
    std::atomic_bool m_acceptPackets {false};
    std::atomic_bool m_stopRequested {false};
    std::atomic<quint64> m_rowsWritten {0};
    std::atomic<quint64> m_droppedPackets {0};
    mutable std::mutex m_controlMutex;
    std::mutex m_threadMutex;
    std::thread m_thread;

    std::mutex m_startMutex;
    std::condition_variable m_startCondition;
    bool m_startResolved = false;
    bool m_startSucceeded = false;
    QString m_startError;

    QString m_filePath;
    quint32 m_sampleRate = 0;
    quint32 m_groupsPerPacket = 0;
};
