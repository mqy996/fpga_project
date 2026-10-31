#include "csvrecorder.h"

#include <QByteArray>
#include <QSaveFile>

#include <charconv>
#include <chrono>
#include <cstring>
#include <system_error>

namespace {
quint32 be32(const char *p) {
    const auto *b = reinterpret_cast<const unsigned char *>(p);
    return (quint32(b[0]) << 24) | (quint32(b[1]) << 16) |
           (quint32(b[2]) << 8) | quint32(b[3]);
}

qint16 be16s(const char *p) {
    const auto *b = reinterpret_cast<const unsigned char *>(p);
    return qint16((quint16(b[0]) << 8) | quint16(b[1]));
}

template <typename Integer>
void appendInteger(QByteArray &buffer, Integer value) {
    char text[32];
    const auto result = std::to_chars(text, text + sizeof(text), value);
    if (result.ec == std::errc()) buffer.append(text, int(result.ptr - text));
}

QByteArray makeHeader() {
    QByteArray header("\xEF\xBB\xBFpacket_sequence\tsample_index\ttime_us");
    for (int channel = 0; channel < 24; ++channel) {
        header.append('\t');
        header.append("CH");
        if (channel < 10) header.append('0');
        appendInteger(header, channel);
        header.append("_code");
        header.append('\t');
        header.append("CH");
        if (channel < 10) header.append('0');
        appendInteger(header, channel);
        header.append("_V");
    }
    header.append("\r\n");
    return header;
}

void appendVoltage(QByteArray &buffer, qint16 code) {
    const double voltage = (double(code) * 10.0) / 32768.0;
    if (voltage >= 0.0) buffer.append('+');
    char text[32];
    const auto result = std::to_chars(text, text + sizeof(text), voltage,
                                      std::chars_format::fixed, 4);
    if (result.ec == std::errc()) buffer.append(text, int(result.ptr - text));
}
}

CsvRecorder::CsvRecorder(QObject *parent) : QObject(parent) {}

CsvRecorder::~CsvRecorder() {
    stopAndWait();
}

bool CsvRecorder::start(const QString &filePath, quint32 sampleRate,
                        quint32 groupsPerPacket, quint32 channelMask,
                        QString *errorMessage) {
    if (errorMessage) errorMessage->clear();
    if (filePath.trimmed().isEmpty() || sampleRate == 0 || groupsPerPacket == 0 ||
        channelMask != 0x00ffffffu) {
        if (errorMessage) *errorMessage = QStringLiteral("需要有效文件名、采样率，并且必须启用全部24路通道。");
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(m_controlMutex);
        if (m_state.load(std::memory_order_acquire) != State::Idle) {
            if (errorMessage) *errorMessage = QStringLiteral("上一次数据文件仍在写入或收尾。");
            return false;
        }
        {
            std::lock_guard<std::mutex> threadLock(m_threadMutex);
            if (m_thread.joinable()) m_thread.join();
        }
        try {
            if (m_slots.size() != kQueueSlots) m_slots.resize(size_t(kQueueSlots));
        } catch (const std::bad_alloc &) {
            if (errorMessage) *errorMessage = QStringLiteral("无法为高速记录分配缓冲区。");
            return false;
        }
        m_head.store(0, std::memory_order_relaxed);
        m_tail.store(0, std::memory_order_relaxed);
        m_rowsWritten.store(0, std::memory_order_relaxed);
        m_droppedPackets.store(0, std::memory_order_relaxed);
        m_acceptPackets.store(false, std::memory_order_relaxed);
        m_stopRequested.store(false, std::memory_order_relaxed);
        m_filePath = filePath;
        m_sampleRate = sampleRate;
        m_groupsPerPacket = groupsPerPacket;
        m_state.store(State::Starting, std::memory_order_release);
        {
            std::lock_guard<std::mutex> startLock(m_startMutex);
            m_startResolved = false;
            m_startSucceeded = false;
            m_startError.clear();
        }
        {
            std::lock_guard<std::mutex> threadLock(m_threadMutex);
            try {
                m_thread = std::thread(&CsvRecorder::run, this);
            } catch (const std::system_error &) {
                m_state.store(State::Idle, std::memory_order_release);
                if (errorMessage) *errorMessage = QStringLiteral("无法创建TXT写入线程。");
                return false;
            }
        }
    }

    bool started = false;
    QString startupError;
    {
        std::unique_lock<std::mutex> lock(m_startMutex);
        m_startCondition.wait(lock, [this] { return m_startResolved; });
        started = m_startSucceeded;
        startupError = m_startError;
    }

    if (!started) {
        std::lock_guard<std::mutex> threadLock(m_threadMutex);
        if (m_thread.joinable()) m_thread.join();
        if (errorMessage) *errorMessage = startupError;
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(m_controlMutex);
        if (m_state.load(std::memory_order_acquire) != State::Starting) {
            if (errorMessage) *errorMessage = QStringLiteral("数据文件未能进入记录状态。");
            return false;
        }
        m_state.store(State::Recording, std::memory_order_release);
        m_acceptPackets.store(true, std::memory_order_release);
    }
    return true;
}

void CsvRecorder::enqueuePacket(const char *bytes, quint16 size) {
    if (!m_acceptPackets.load(std::memory_order_acquire)) return;
    std::lock_guard<std::mutex> lock(m_controlMutex);
    if (!m_acceptPackets.load(std::memory_order_relaxed)) return;
    if (!push(bytes, size)) m_droppedPackets.fetch_add(1, std::memory_order_relaxed);
}

void CsvRecorder::stop() {
    std::lock_guard<std::mutex> lock(m_controlMutex);
    const State state = m_state.load(std::memory_order_acquire);
    if (state == State::Recording || state == State::Starting) {
        m_acceptPackets.store(false, std::memory_order_release);
        m_stopRequested.store(true, std::memory_order_release);
        m_state.store(State::Stopping, std::memory_order_release);
    }
}

void CsvRecorder::stopAndWait() {
    stop();
    std::lock_guard<std::mutex> threadLock(m_threadMutex);
    if (m_thread.joinable() && m_thread.get_id() != std::this_thread::get_id())
        m_thread.join();
}

bool CsvRecorder::isRecording() const {
    return m_state.load(std::memory_order_acquire) == State::Recording;
}

bool CsvRecorder::isBusy() const {
    return m_state.load(std::memory_order_acquire) != State::Idle;
}

quint64 CsvRecorder::rowsWritten() const {
    return m_rowsWritten.load(std::memory_order_acquire);
}

quint64 CsvRecorder::droppedPackets() const {
    return m_droppedPackets.load(std::memory_order_acquire);
}

bool CsvRecorder::push(const char *bytes, quint16 size) {
    const quint64 head = m_head.load(std::memory_order_relaxed);
    const quint64 tail = m_tail.load(std::memory_order_acquire);
    if (head - tail >= kQueueSlots) return false;
    PacketSlot &slot = m_slots[size_t(head % kQueueSlots)];
    std::memcpy(slot.bytes.data(), bytes, size);
    slot.size = size;
    m_head.store(head + 1, std::memory_order_release);
    return true;
}

bool CsvRecorder::pop(PacketSlot *slot) {
    const quint64 tail = m_tail.load(std::memory_order_relaxed);
    const quint64 head = m_head.load(std::memory_order_acquire);
    if (tail == head) return false;
    if (slot) *slot = m_slots[size_t(tail % kQueueSlots)];
    m_tail.store(tail + 1, std::memory_order_release);
    return true;
}

quint64 CsvRecorder::queueDepth() const {
    const quint64 head = m_head.load(std::memory_order_acquire);
    const quint64 tail = m_tail.load(std::memory_order_acquire);
    return head - tail;
}

void CsvRecorder::run() {
    const QString path = m_filePath;
    const quint32 sampleRate = m_sampleRate;
    const quint32 groupsPerPacket = m_groupsPerPacket;
    QSaveFile file(path);
    file.setDirectWriteFallback(false);
    QString error;

    auto resolveStartup = [this](bool succeeded, const QString &message) {
        {
            std::lock_guard<std::mutex> lock(m_startMutex);
            m_startSucceeded = succeeded;
            m_startError = message;
            m_startResolved = true;
        }
        m_startCondition.notify_one();
    };

    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
		error = QStringLiteral("无法创建TXT文件：%1").arg(file.errorString());
        m_state.store(State::Idle, std::memory_order_release);
        resolveStartup(false, error);
        return;
    }
    const QByteArray header = makeHeader();
    if (file.write(header) != header.size()) {
		error = QStringLiteral("无法写入TXT表头：%1").arg(file.errorString());
        file.cancelWriting();
        m_state.store(State::Idle, std::memory_order_release);
        resolveStartup(false, error);
        return;
    }
    resolveStartup(true, {});

    QByteArray buffer;
    buffer.reserve(4 * 1024 * 1024);
    PacketSlot packet;
    quint64 rows = 0;
    quint64 sequenceEpoch = 0;
    quint32 lastSequence = 0;
    bool haveSequence = false;
    bool failed = false;
    const auto flush = [&]() -> bool {
        if (buffer.isEmpty()) return true;
        const qint64 written = file.write(buffer.constData(), buffer.size());
        if (written != buffer.size()) {
			error = QStringLiteral("TXT写入失败：%1").arg(file.errorString());
            return false;
        }
        buffer.clear();
        m_rowsWritten.store(rows, std::memory_order_release);
        return true;
    };

    while (true) {
        bool consumedPacket = false;
        while (pop(&packet)) {
            consumedPacket = true;
            if (packet.size < 12 + int(groupsPerPacket * 24u * 2u)) {
                m_droppedPackets.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            const quint32 sequence = be32(packet.bytes.data());
            quint64 packetEpoch = sequenceEpoch;
            if (!haveSequence) {
                haveSequence = true;
                lastSequence = sequence;
            } else {
                const quint32 forwardDistance = sequence - lastSequence;
                if (forwardDistance != 0 && forwardDistance < 0x80000000u) {
                    if (sequence < lastSequence) ++sequenceEpoch;
                    lastSequence = sequence;
                    packetEpoch = sequenceEpoch;
                } else if (forwardDistance >= 0x80000000u && sequence > lastSequence &&
                           sequenceEpoch > 0) {
                    // A delayed packet from just before the 32-bit sequence wrap.
                    packetEpoch = sequenceEpoch - 1;
                }
            }
            const quint64 extendedSequence = (packetEpoch << 32) | sequence;
            const quint64 packetSampleIndex =
                (extendedSequence > 0 ? extendedSequence - 1u : 0u) * quint64(groupsPerPacket);
            int offset = 12;
            for (quint32 group = 0; group < groupsPerPacket; ++group) {
                const quint64 sampleIndex = packetSampleIndex + group;
                const quint64 timeUs = (sampleIndex * 1000000u) / sampleRate;
                appendInteger(buffer, sequence);
                buffer.append('\t');
                appendInteger(buffer, sampleIndex);
                buffer.append('\t');
                appendInteger(buffer, timeUs);
                for (int channel = 0; channel < 24; ++channel) {
                    buffer.append('\t');
                    const qint16 code = be16s(packet.bytes.data() + offset);
                    appendInteger(buffer, int(code));
                    buffer.append('\t');
                    appendVoltage(buffer, code);
                    offset += 2;
                }
                buffer.append("\r\n");
                ++rows;
            }
            if (buffer.size() >= 4 * 1024 * 1024 && !flush()) {
                failed = true;
                break;
            }
        }
        if (failed) break;
        if (m_stopRequested.load(std::memory_order_acquire) && queueDepth() == 0) break;
        if (!consumedPacket) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (!failed && !flush()) failed = true;
    if (!failed && rows == 0) {
		error = QStringLiteral("本次没有收到采样数据，未生成TXT文件。");
        failed = true;
    }
    if (!failed && !file.commit()) {
		error = QStringLiteral("TXT提交失败：%1").arg(file.errorString());
        failed = true;
    }
    if (failed) file.cancelWriting();

    if (failed) {
        std::lock_guard<std::mutex> lock(m_controlMutex);
        m_acceptPackets.store(false, std::memory_order_release);
        m_stopRequested.store(true, std::memory_order_release);
        m_state.store(State::Stopping, std::memory_order_release);
    }
    m_rowsWritten.store(rows, std::memory_order_release);
    const quint64 remainingPackets = queueDepth();
    if (failed && remainingPackets > 0)
        m_droppedPackets.fetch_add(remainingPackets, std::memory_order_relaxed);

    {
        std::lock_guard<std::mutex> lock(m_controlMutex);
        m_acceptPackets.store(false, std::memory_order_release);
        m_state.store(State::Idle, std::memory_order_release);
    }
    emit recordingFinished(path, rows, m_droppedPackets.load(std::memory_order_acquire), error);
}
