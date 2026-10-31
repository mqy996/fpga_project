#pragma once

#include <QtGlobal>

namespace AdcDisplay {
constexpr double kInputRangeVolts = 10.0;
constexpr int kHistoryBucketMs = 10;
constexpr int kRecentStatisticsSeconds = 10 * 60;
constexpr int kMaximumHistorySeconds = 30 * 60;
constexpr int kMaximumHistoryBuckets = (kMaximumHistorySeconds * 1000) / kHistoryBucketMs;
// The long history is intentionally compact (10 ms min/max buckets).  A
// separate recent tier keeps enough phase information to inspect a waveform.
constexpr int kFineHistoryBucketUs = 50;
constexpr int kFineHistoryMilliseconds = 5 * 1000;
constexpr int kFineHistoryBuckets = (kFineHistoryMilliseconds * 1000) / kFineHistoryBucketUs;
constexpr int kWaveRenderBuckets = 2048;

inline double codeToVolts(qint16 code) {
    return (double(code) * kInputRangeVolts) / 32768.0;
}
}
