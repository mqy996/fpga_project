#include "dataworker.h"

#include <QElapsedTimer>
#include <QMutexLocker>
#include <QString>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <thread>

#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

namespace {
constexpr int kReceiveBufferBytes = 64 * 1024 * 1024;
constexpr quint64 kInvalidBucket = std::numeric_limits<quint64>::max();

quint32 be32(const char *p) {
    const auto *b = reinterpret_cast<const unsigned char *>(p);
    return (quint32(b[0]) << 24) | (quint32(b[1]) << 16) |
           (quint32(b[2]) << 8) | quint32(b[3]);
}

qint16 be16s(const char *p) {
    const auto *b = reinterpret_cast<const unsigned char *>(p);
    return qint16((quint16(b[0]) << 8) | quint16(b[1]));
}

bool setAddress(sockaddr_in &address, const QHostAddress &host, quint16 port) {
    address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    return InetPtonA(AF_INET, host.toString().toLatin1().constData(), &address.sin_addr) == 1;
}
}

template <int BucketCount>
UdpDataWorker::TimeHistory<BucketCount>::TimeHistory() : buckets(BucketCount) {
    clear();
}

template <int BucketCount>
void UdpDataWorker::TimeHistory<BucketCount>::clear() {
    for (auto &bucket : buckets) bucket.index = kInvalidBucket;
}

template <int BucketCount>
void UdpDataWorker::TimeHistory<BucketCount>::add(quint64 bucketIndex, qint16 value) {
    TimeBucket &bucket = buckets[int(bucketIndex % quint64(buckets.size()))];
    if (bucket.index != bucketIndex) {
        bucket.index = bucketIndex;
        bucket.minimum = value;
        bucket.maximum = value;
    } else {
        bucket.minimum = std::min(bucket.minimum, value);
        bucket.maximum = std::max(bucket.maximum, value);
    }
}

template <int BucketCount>
bool UdpDataWorker::TimeHistory<BucketCount>::get(quint64 bucketIndex, TimeBucket *bucket) const {
    const TimeBucket &candidate = buckets[int(bucketIndex % quint64(buckets.size()))];
    if (candidate.index != bucketIndex) return false;
    if (bucket) *bucket = candidate;
    return true;
}

UdpDataWorker::PacketRing::PacketRing() : m_slots(kQueueSlots) {}

bool UdpDataWorker::PacketRing::push(const char *bytes, quint16 size, quint64 generation) {
    const quint64 head = m_head.load(std::memory_order_relaxed);
    const quint64 tail = m_tail.load(std::memory_order_acquire);
    if (head - tail >= kQueueSlots) return false;
    PacketSlot &slot = m_slots[size_t(head % kQueueSlots)];
    std::memcpy(slot.bytes.data(), bytes, size);
    slot.size = size;
    slot.generation = generation;
    m_head.store(head + 1, std::memory_order_release);
    return true;
}

bool UdpDataWorker::PacketRing::pop(PacketSlot *slot) {
    const quint64 tail = m_tail.load(std::memory_order_relaxed);
    const quint64 head = m_head.load(std::memory_order_acquire);
    if (tail == head) return false;
    if (slot) *slot = m_slots[size_t(tail % kQueueSlots)];
    m_tail.store(tail + 1, std::memory_order_release);
    return true;
}

quint64 UdpDataWorker::PacketRing::depth() const {
    const quint64 head = m_head.load(std::memory_order_acquire);
    const quint64 tail = m_tail.load(std::memory_order_acquire);
    return head - tail;
}

bool UdpDataWorker::PacketRing::empty() const { return depth() == 0; }

UdpDataWorker::UdpDataWorker(QObject *parent) : QThread(parent) {
    connect(&m_csvRecorder, &CsvRecorder::recordingFinished,
            this, &UdpDataWorker::csvRecordingFinished);
}

UdpDataWorker::~UdpDataWorker() {
    stopMonitoring();
    wait();
}

void UdpDataWorker::resetReceiverCounters() {
    m_receivedPackets.store(0, std::memory_order_relaxed);
    m_receiverLost.store(0, std::memory_order_relaxed);
    m_receiverDuplicates.store(0, std::memory_order_relaxed);
    m_receiverOutOfOrder.store(0, std::memory_order_relaxed);
    m_receiverLengthErrors.store(0, std::memory_order_relaxed);
    m_receiverHeaderErrors.store(0, std::memory_order_relaxed);
    m_receiverSourceErrors.store(0, std::memory_order_relaxed);
    m_receiverSocketErrors.store(0, std::memory_order_relaxed);
    m_queueOverflows.store(0, std::memory_order_relaxed);
    m_receiverElapsedMs.store(0, std::memory_order_relaxed);
    m_receiverRecentRate.store(0.0, std::memory_order_relaxed);
}

bool UdpDataWorker::startMonitoring(const FpgaProtocol::DeviceConfig &config,
                                    const QHostAddress &bindAddress,
                                    const QHostAddress &allowedSource,
                                    const QVector<int> &waveChannels,
                                    int waveWindowMilliseconds) {
    if (isRunning()) return false;
    QMutexLocker lock(&m_mutex);
    m_config = config;
    m_bindAddress = bindAddress;
    m_allowedSource = allowedSource;
    quint32 mask = 0;
    for (int channel : waveChannels) {
        if (channel >= 0 && channel < 24) mask |= (1u << channel);
    }
    m_waveMask.store(mask, std::memory_order_release);
    m_waveWindowMilliseconds = std::clamp(waveWindowMilliseconds, 1,
                                           AdcDisplay::kMaximumHistorySeconds * 1000);
    m_waveFollowLatest = true;
    m_waveViewEndGroupIndex = 0;
    m_snapshot = {};
    m_stop.store(false, std::memory_order_release);
    m_udpReady.store(false, std::memory_order_release);
    m_generation.store(1, std::memory_order_release);
    resetReceiverCounters();
    start();
    return true;
}

void UdpDataWorker::stopMonitoring() { m_stop.store(true, std::memory_order_release); }

void UdpDataWorker::setWaveChannels(const QVector<int> &channels) {
    quint32 mask = 0;
    for (int channel : channels) {
        if (channel >= 0 && channel < 24) mask |= (1u << channel);
    }
    m_waveMask.store(mask, std::memory_order_release);
}

void UdpDataWorker::setWaveChannelEnabled(int channel, bool enabled) {
    if (channel < 0 || channel >= 24) return;
    const quint32 bit = (1u << channel);
    if (enabled) m_waveMask.fetch_or(bit, std::memory_order_release);
    else m_waveMask.fetch_and(~bit, std::memory_order_release);
}

void UdpDataWorker::setWaveWindowMilliseconds(int milliseconds) {
    QMutexLocker lock(&m_mutex);
    m_waveWindowMilliseconds = std::clamp(milliseconds, 1,
                                           AdcDisplay::kMaximumHistorySeconds * 1000);
}

void UdpDataWorker::setWaveViewAnchor(quint64 endGroupIndex) {
    QMutexLocker lock(&m_mutex);
    m_waveFollowLatest = false;
    m_waveViewEndGroupIndex = endGroupIndex;
}

void UdpDataWorker::followWaveLatest() {
    QMutexLocker lock(&m_mutex);
    m_waveFollowLatest = true;
}

void UdpDataWorker::requestClear() {
    {
        QMutexLocker lock(&m_mutex);
        m_waveFollowLatest = true;
        m_waveViewEndGroupIndex = 0;
    }
    // Packets already in the SPSC queue carry the old generation and will be
    // ignored by the processor after this point.
    m_generation.fetch_add(1, std::memory_order_acq_rel);
}

bool UdpDataWorker::startCsvRecording(const QString &filePath, QString *errorMessage) {
    std::lock_guard<std::mutex> lifecycleLock(m_recorderLifecycleMutex);
    if (!isRunning() || !isUdpReady()) {
        if (errorMessage) *errorMessage = QStringLiteral("请先开始采集并等待UDP监测启动。");
        return false;
    }
    FpgaProtocol::DeviceConfig config;
    {
        QMutexLocker lock(&m_mutex);
        config = m_config;
    }
    if (config.channelMask != 0x00ffffffu) {
        if (errorMessage) *errorMessage = QStringLiteral("当前UDP配置未启用全部24路。请停止采集，将通道掩码设为CH00–CH23后重新开始。");
        return false;
    }
    return m_csvRecorder.start(filePath, config.sampleRate, config.groupsPerPacket,
                               config.channelMask, errorMessage);
}

void UdpDataWorker::stopCsvRecording() { m_csvRecorder.stop(); }
bool UdpDataWorker::isCsvRecording() const { return m_csvRecorder.isRecording(); }
bool UdpDataWorker::isCsvRecorderBusy() const { return m_csvRecorder.isBusy(); }
quint64 UdpDataWorker::csvRowsWritten() const { return m_csvRecorder.rowsWritten(); }
quint64 UdpDataWorker::csvDroppedPackets() const { return m_csvRecorder.droppedPackets(); }

MonitorSnapshot UdpDataWorker::snapshot() const {
    QMutexLocker lock(&m_mutex);
    return m_snapshot;
}

void UdpDataWorker::resetLocal(Statistics &stats,
                               std::array<CoarseTimeHistory, 24> &history,
                               std::array<FineTimeHistory, 24> &fineHistory,
                               quint64 &latestBucket, quint64 &latestFineBucket,
                               quint64 &latestGroupIndex) {
    stats = {};
    latestBucket = 0;
    latestFineBucket = 0;
    latestGroupIndex = 0;
    for (int channel = 0; channel < 24; ++channel) {
        stats.minimum[channel] = std::numeric_limits<qint16>::max();
        stats.maximum[channel] = std::numeric_limits<qint16>::min();
        history[channel].clear();
        fineHistory[channel].clear();
    }
}

void UdpDataWorker::publish(const Statistics &stats,
                            const std::array<CoarseTimeHistory, 24> &history,
                            const std::array<FineTimeHistory, 24> &fineHistory,
                            quint64 latestBucket, quint64 latestFineBucket,
                            quint64 latestGroupIndex, quint64 receiveBufferBytes,
                            quint64 queueDepth) {
    MonitorSnapshot next;
    next.packets = stats.packets;
    next.receivedPackets = m_receivedPackets.load(std::memory_order_acquire);
    next.lost = m_receiverLost.load(std::memory_order_acquire);
    next.duplicates = m_receiverDuplicates.load(std::memory_order_acquire);
    next.outOfOrder = m_receiverOutOfOrder.load(std::memory_order_acquire);
    next.lengthErrors = m_receiverLengthErrors.load(std::memory_order_acquire);
    next.headerErrors = m_receiverHeaderErrors.load(std::memory_order_acquire);
    next.sourceErrors = m_receiverSourceErrors.load(std::memory_order_acquire);
    next.socketErrors = m_receiverSocketErrors.load(std::memory_order_acquire);
    next.queueOverflows = m_queueOverflows.load(std::memory_order_acquire);
    next.queueDepth = queueDepth;
    next.receiveBufferBytes = receiveBufferBytes;
    next.elapsedMs = m_receiverElapsedMs.load(std::memory_order_acquire);
    next.averagePacketRate = next.elapsedMs > 0
        ? double(next.receivedPackets) * 1000.0 / double(next.elapsedMs) : 0.0;
    next.recentPacketRate = m_receiverRecentRate.load(std::memory_order_acquire);

    quint32 mask = m_waveMask.load(std::memory_order_acquire);
    quint32 sampleRate = 0;
    int waveWindowMilliseconds = 60 * 1000;
    bool waveFollowLatest = true;
    quint64 requestedViewEndGroup = 0;
    {
        QMutexLocker lock(&m_mutex);
        sampleRate = m_config.sampleRate;
        waveWindowMilliseconds = m_waveWindowMilliseconds;
        waveFollowLatest = m_waveFollowLatest;
        requestedViewEndGroup = m_waveViewEndGroupIndex;
    }
    next.waveWindowMilliseconds = waveWindowMilliseconds;
    next.waveSampleRate = sampleRate;
    next.latestGroupIndex = latestGroupIndex;

    const quint64 windowGroups = WaveView::groupsForMilliseconds(sampleRate, waveWindowMilliseconds);
    const quint64 fineRetainedGroups = WaveView::groupsForMilliseconds(
        sampleRate, AdcDisplay::kFineHistoryMilliseconds);
    const quint64 coarseRetainedGroups = WaveView::groupsForMilliseconds(
        sampleRate, AdcDisplay::kMaximumHistorySeconds * 1000);
    const quint64 provisionalEnd = waveFollowLatest ? latestGroupIndex : requestedViewEndGroup;
    const bool provisionalFine = WaveView::canUseFineHistory(provisionalEnd, latestGroupIndex,
                                                               sampleRate, waveWindowMilliseconds);
    const quint64 retainedGroups = provisionalFine ? fineRetainedGroups : coarseRetainedGroups;
    const quint64 viewEndGroup = waveFollowLatest ? latestGroupIndex :
        WaveView::clampViewEnd(provisionalEnd, latestGroupIndex, windowGroups, retainedGroups);
    const bool useFineHistory = WaveView::canUseFineHistory(viewEndGroup, latestGroupIndex,
                                                             sampleRate, waveWindowMilliseconds);
    if (!waveFollowLatest && viewEndGroup == latestGroupIndex) {
        QMutexLocker lock(&m_mutex);
        if (!m_waveFollowLatest && m_waveViewEndGroupIndex >= latestGroupIndex)
            m_waveFollowLatest = true;
        waveFollowLatest = m_waveFollowLatest;
    }
    next.viewEndGroupIndex = viewEndGroup;
    next.waveFollowsLatest = waveFollowLatest;
    next.waveUsesFineHistory = useFineHistory;

    const quint64 recentBuckets = quint64((AdcDisplay::kRecentStatisticsSeconds * 1000) /
                                            AdcDisplay::kHistoryBucketMs);
    const quint64 recentStart = latestBucket >= recentBuckets ? latestBucket - recentBuckets + 1 : 0;
    const quint64 windowBuckets = useFineHistory
        ? (quint64(waveWindowMilliseconds) * 1000 + AdcDisplay::kFineHistoryBucketUs - 1) /
              AdcDisplay::kFineHistoryBucketUs
        : (quint64(waveWindowMilliseconds) + AdcDisplay::kHistoryBucketMs - 1) /
              AdcDisplay::kHistoryBucketMs;
    const quint64 latestWaveBucket = useFineHistory
        ? (viewEndGroup * 1000000u) / (quint64(sampleRate) * AdcDisplay::kFineHistoryBucketUs)
        : (viewEndGroup * 1000u) / (quint64(sampleRate) * AdcDisplay::kHistoryBucketMs);
    const qint64 windowStart = qint64(latestWaveBucket) - qint64(windowBuckets) + 1;
    const int renderBuckets = std::min(AdcDisplay::kWaveRenderBuckets, int(windowBuckets));

    for (int channel = 0; channel < 24; ++channel) {
        next.channels[channel].samples = stats.count[channel];
        next.channels[channel].minimum = stats.count[channel] ? stats.minimum[channel] : 0;
        next.channels[channel].maximum = stats.count[channel] ? stats.maximum[channel] : 0;
        next.channels[channel].mean = stats.count[channel]
            ? double(stats.sum[channel]) / double(stats.count[channel]) : 0.0;
        next.channels[channel].hasLatest = stats.count[channel] > 0;
        next.channels[channel].latest = stats.latest[channel];

        qint16 recentMinimum = std::numeric_limits<qint16>::max();
        qint16 recentMaximum = std::numeric_limits<qint16>::min();
        bool haveRecent = false;
        for (quint64 bucketIndex = recentStart; bucketIndex <= latestBucket; ++bucketIndex) {
            TimeBucket bucket;
            if (history[channel].get(bucketIndex, &bucket)) {
                haveRecent = true;
                recentMinimum = std::min(recentMinimum, bucket.minimum);
                recentMaximum = std::max(recentMaximum, bucket.maximum);
            }
            if (bucketIndex == std::numeric_limits<quint64>::max()) break;
        }
        next.channels[channel].hasRecent = haveRecent;
        next.channels[channel].recentMinimum = haveRecent ? recentMinimum : 0;
        next.channels[channel].recentMaximum = haveRecent ? recentMaximum : 0;

        if (((mask >> channel) & 1u) == 0) continue;
        next.waveEnabled[channel] = true;
        auto &rendered = next.waves[channel];
        rendered.resize(renderBuckets);
        for (int segment = 0; segment < renderBuckets; ++segment) {
            const qint64 start = windowStart + qint64((quint64(segment) * windowBuckets) /
                                                       quint64(renderBuckets));
            const qint64 end = windowStart + qint64((quint64(segment + 1) * windowBuckets) /
                                                     quint64(renderBuckets));
            qint16 minimum = std::numeric_limits<qint16>::max();
            qint16 maximum = std::numeric_limits<qint16>::min();
            bool valid = false;
            for (qint64 bucketIndex = start; bucketIndex < end; ++bucketIndex) {
                if (bucketIndex < 0) continue;
                TimeBucket bucket;
                const bool have = useFineHistory
                    ? fineHistory[channel].get(quint64(bucketIndex), &bucket)
                    : history[channel].get(quint64(bucketIndex), &bucket);
                if (!have) continue;
                valid = true;
                minimum = std::min(minimum, bucket.minimum);
                maximum = std::max(maximum, bucket.maximum);
            }
            rendered[segment].valid = valid;
            rendered[segment].minimum = valid ? minimum : 0;
            rendered[segment].maximum = valid ? maximum : 0;
        }
        next.waveChannels.push_back(channel);
    }

    QMutexLocker lock(&m_mutex);
    m_snapshot = std::move(next);
}

void UdpDataWorker::processPackets(PacketRing &queue, const std::atomic_bool &receiverFinished,
                                   quint64 receiveBufferBytes) {
    FpgaProtocol::DeviceConfig config;
    {
        QMutexLocker lock(&m_mutex);
        config = m_config;
    }

    Statistics stats;
    std::array<CoarseTimeHistory, 24> history;
    std::array<FineTimeHistory, 24> fineHistory;
    quint64 latestBucket = 0;
    quint64 latestFineBucket = 0;
    quint64 latestGroupIndex = 0;
    resetLocal(stats, history, fineHistory, latestBucket, latestFineBucket, latestGroupIndex);

    quint64 pendingBucket = kInvalidBucket;
    std::array<qint16, 24> pendingMinimum {};
    std::array<qint16, 24> pendingMaximum {};
    std::array<bool, 24> pendingValid {};
    const auto clearPending = [&] {
        pendingBucket = kInvalidBucket;
        pendingValid.fill(false);
    };
    const auto flushPending = [&] {
        if (pendingBucket == kInvalidBucket) return;
        for (int channel = 0; channel < 24; ++channel) {
            if (!pendingValid[channel]) continue;
            history[channel].add(pendingBucket, pendingMinimum[channel]);
            history[channel].add(pendingBucket, pendingMaximum[channel]);
        }
    };

    quint64 generation = m_generation.load(std::memory_order_acquire);
    QElapsedTimer publishTimer;
    publishTimer.start();
    qint64 lastPublishMs = 0;
    PacketSlot slot;

    while (!receiverFinished.load(std::memory_order_acquire) || !queue.empty()) {
        const quint64 currentGeneration = m_generation.load(std::memory_order_acquire);
        if (generation != currentGeneration) {
            generation = currentGeneration;
            resetLocal(stats, history, fineHistory, latestBucket, latestFineBucket, latestGroupIndex);
            clearPending();
        }

        if (!queue.pop(&slot)) {
            const qint64 now = publishTimer.elapsed();
            if (now - lastPublishMs >= 200) {
                flushPending();
                publish(stats, history, fineHistory, latestBucket, latestFineBucket, latestGroupIndex,
                        receiveBufferBytes, queue.depth());
                lastPublishMs = now;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        if (slot.generation != generation) continue;

        const quint32 sequence = be32(slot.bytes.data());
        const quint32 waveMask = m_waveMask.load(std::memory_order_relaxed);
        int offset = 12;
        for (quint32 group = 0; group < config.groupsPerPacket; ++group) {
            const quint64 groupIndex = (quint64(sequence) - 1u) * config.groupsPerPacket + group;
            const quint64 bucketIndex = (groupIndex * 1000u) /
                (quint64(config.sampleRate) * AdcDisplay::kHistoryBucketMs);
            const quint64 fineBucketIndex = (groupIndex * 1000000u) /
                (quint64(config.sampleRate) * AdcDisplay::kFineHistoryBucketUs);
            latestBucket = std::max(latestBucket, bucketIndex);
            latestFineBucket = std::max(latestFineBucket, fineBucketIndex);
            latestGroupIndex = std::max(latestGroupIndex, groupIndex);
            if (pendingBucket != bucketIndex) {
                flushPending();
                pendingBucket = bucketIndex;
                pendingValid.fill(false);
            }
            for (int channel = 0; channel < 24; ++channel) {
                if (((config.channelMask >> channel) & 1u) == 0) continue;
                const qint16 value = be16s(slot.bytes.data() + offset);
                offset += 2;
                ++stats.count[channel];
                stats.minimum[channel] = std::min(stats.minimum[channel], value);
                stats.maximum[channel] = std::max(stats.maximum[channel], value);
                stats.latest[channel] = value;
                stats.sum[channel] += value;
                if (!pendingValid[channel]) {
                    pendingValid[channel] = true;
                    pendingMinimum[channel] = value;
                    pendingMaximum[channel] = value;
                } else {
                    pendingMinimum[channel] = std::min(pendingMinimum[channel], value);
                    pendingMaximum[channel] = std::max(pendingMaximum[channel], value);
                }
                if ((waveMask >> channel) & 1u)
                    fineHistory[channel].add(fineBucketIndex, value);
            }
        }
        ++stats.packets;

        const qint64 now = publishTimer.elapsed();
        if (now - lastPublishMs >= 200) {
            flushPending();
            publish(stats, history, fineHistory, latestBucket, latestFineBucket, latestGroupIndex,
                    receiveBufferBytes, queue.depth());
            lastPublishMs = now;
        }
    }

    flushPending();
    publish(stats, history, fineHistory, latestBucket, latestFineBucket, latestGroupIndex,
            receiveBufferBytes, queue.depth());
}

void UdpDataWorker::run() {
    FpgaProtocol::DeviceConfig config;
    QHostAddress bindAddress;
    QHostAddress allowedSource;
    {
        QMutexLocker lock(&m_mutex);
        config = m_config;
        bindAddress = m_bindAddress;
        allowedSource = m_allowedSource;
    }

    WSADATA wsa {};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        emit monitorOpened(false, QStringLiteral("WinSock 初始化失败。"));
        return;
    }
    SOCKET socketHandle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketHandle == INVALID_SOCKET) {
        WSACleanup();
        emit monitorOpened(false, QStringLiteral("无法创建UDP接收套接字。"));
        return;
    }

    int receiveBuffer = kReceiveBufferBytes;
    setsockopt(socketHandle, SOL_SOCKET, SO_RCVBUF,
               reinterpret_cast<const char *>(&receiveBuffer), sizeof(receiveBuffer));
    int actualBuffer = 0;
    int actualLength = sizeof(actualBuffer);
    getsockopt(socketHandle, SOL_SOCKET, SO_RCVBUF,
               reinterpret_cast<char *>(&actualBuffer), &actualLength);
    DWORD timeout = 100;
    setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char *>(&timeout), sizeof(timeout));

    sockaddr_in local {};
    if (!setAddress(local, bindAddress, config.dataPort) ||
        bind(socketHandle, reinterpret_cast<sockaddr *>(&local), sizeof(local)) == SOCKET_ERROR) {
        const int error = WSAGetLastError();
        closesocket(socketHandle);
        WSACleanup();
        emit monitorOpened(false, QStringLiteral("无法绑定 %1:%2，WSA=%3。请关闭占用数据端口的程序。")
             .arg(bindAddress.toString()).arg(config.dataPort).arg(error));
        return;
    }

    // Keep the socket drain path ahead of painting and history aggregation,
    // without using THREAD_PRIORITY_TIME_CRITICAL.
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);

    PacketRing queue;
    std::atomic_bool receiverFinished {false};
    std::thread processor([this, &queue, &receiverFinished, actualBuffer] {
        processPackets(queue, receiverFinished, quint64(actualBuffer));
    });

    m_udpReady.store(true, std::memory_order_release);
    emit monitorOpened(true, QStringLiteral("已监听 %1:%2，SO_RCVBUF=%3字节，处理队列=%4包。")
         .arg(bindAddress.toString()).arg(config.dataPort).arg(actualBuffer).arg(kQueueSlots));

    std::array<char, kPacketBytes> packet {};
    quint32 expectedSequence = 1;
    bool sequenceStarted = false;
    quint64 localGeneration = m_generation.load(std::memory_order_acquire);
    QElapsedTimer rateTimer;
    rateTimer.start();
    qint64 rateStartMs = 0;
    quint64 rateStartPackets = 0;

    while (!m_stop.load(std::memory_order_acquire)) {
        const quint64 generation = m_generation.load(std::memory_order_acquire);
        if (generation != localGeneration) {
            localGeneration = generation;
            expectedSequence = 1;
            sequenceStarted = false;
            resetReceiverCounters();
            rateTimer.restart();
            rateStartMs = 0;
            rateStartPackets = 0;
        }

        sockaddr_in sender {};
        int senderLength = sizeof(sender);
        const int size = recvfrom(socketHandle, packet.data(), int(packet.size()), 0,
                                  reinterpret_cast<sockaddr *>(&sender), &senderLength);
        if (size == SOCKET_ERROR) {
            const int error = WSAGetLastError();
            if (error != WSAETIMEDOUT && error != WSAEWOULDBLOCK)
                m_receiverSocketErrors.fetch_add(1, std::memory_order_relaxed);
        } else {
            char senderText[INET_ADDRSTRLEN] {};
            InetNtopA(AF_INET, &sender.sin_addr, senderText, sizeof(senderText));
            if (QHostAddress(QString::fromLatin1(senderText)) != allowedSource) {
                m_receiverSourceErrors.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            const int expectedLength = int(FpgaProtocol::payloadBytes(config));
            if (size != expectedLength) {
                m_receiverLengthErrors.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            if (be32(packet.data() + 4) != config.sampleRate ||
                be32(packet.data() + 8) != config.channelMask) {
                m_receiverHeaderErrors.fetch_add(1, std::memory_order_relaxed);
                continue;
            }

            const quint32 sequence = be32(packet.data());
            if (!sequenceStarted) {
                sequenceStarted = true;
                expectedSequence = 1;
                rateTimer.restart();
                rateStartMs = 0;
                rateStartPackets = 0;
            }
            if (sequence != expectedSequence) {
                if (sequence == expectedSequence - 1)
                    m_receiverDuplicates.fetch_add(1, std::memory_order_relaxed);
                else if (sequence > expectedSequence)
                    m_receiverLost.fetch_add(sequence - expectedSequence, std::memory_order_relaxed);
                else
                    m_receiverOutOfOrder.fetch_add(1, std::memory_order_relaxed);
            }
            expectedSequence = sequence + 1;
            const quint64 received = m_receivedPackets.fetch_add(1, std::memory_order_relaxed) + 1;
            m_csvRecorder.enqueuePacket(packet.data(), quint16(size));
            if (!queue.push(packet.data(), quint16(size), localGeneration))
                m_queueOverflows.fetch_add(1, std::memory_order_relaxed);

            const qint64 now = rateTimer.elapsed();
            m_receiverElapsedMs.store(quint64(now), std::memory_order_release);
            if (now - rateStartMs >= 1000) {
                const qint64 interval = now - rateStartMs;
                const double rate = interval > 0
                    ? double(received - rateStartPackets) * 1000.0 / double(interval) : 0.0;
                m_receiverRecentRate.store(rate, std::memory_order_release);
                rateStartMs = now;
                rateStartPackets = received;
            }
        }
    }

    receiverFinished.store(true, std::memory_order_release);
    processor.join();
    {
        std::lock_guard<std::mutex> lifecycleLock(m_recorderLifecycleMutex);
        m_csvRecorder.stopAndWait();
        m_udpReady.store(false, std::memory_order_release);
    }
    closesocket(socketHandle);
    WSACleanup();
    emit monitorStopped(QStringLiteral("数据监测已停止。"));
}
