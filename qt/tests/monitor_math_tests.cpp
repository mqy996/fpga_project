#include "adcmath.h"
#include "waveviewmath.h"

#include <cmath>
#include <cstdio>

namespace {
bool closeEnough(double actual, double expected) {
    return std::abs(actual - expected) < 1e-9;
}
}

int main() {
    if (!closeEnough(AdcDisplay::codeToVolts(qint16(-32768)), -10.0)) {
        std::fputs("negative full scale conversion failed\n", stderr);
        return 1;
    }
    if (!closeEnough(AdcDisplay::codeToVolts(qint16(0)), 0.0)) {
        std::fputs("zero conversion failed\n", stderr);
        return 1;
    }
    if (!closeEnough(AdcDisplay::codeToVolts(qint16(16384)), 5.0)) {
        std::fputs("positive half scale conversion failed\n", stderr);
        return 1;
    }
    if (AdcDisplay::kHistoryBucketMs != 10 ||
        AdcDisplay::kMaximumHistoryBuckets != 180000 ||
        AdcDisplay::kRecentStatisticsSeconds != 600) {
        std::fputs("time history constants failed\n", stderr);
        return 1;
    }
    const int vppCode = int(qint16(16384)) - int(qint16(-16384));
    const double vppVolts = AdcDisplay::codeToVolts(qint16(16384)) - AdcDisplay::codeToVolts(qint16(-16384));
    if (vppCode != 32768 || !closeEnough(vppVolts, 10.0)) {
        std::fputs("peak-to-peak conversion failed\n", stderr);
        return 1;
    }
    constexpr quint32 rate = 500000;
    if (WaveView::groupsForMilliseconds(rate, 10) != 5000 ||
        WaveView::groupsForMilliseconds(rate, 1) != 500) {
        std::fputs("view duration to group conversion failed\n", stderr);
        return 1;
    }
    const quint64 latest = 5000000; // ten seconds of 500 kSPS data
    const quint64 tenMsGroups = WaveView::groupsForMilliseconds(rate, 10);
    const quint64 dragged = WaveView::draggedViewEnd(latest, 250, 1000, 10, rate);
    if (dragged != latest - 1250 || !WaveView::canUseFineHistory(dragged, latest, rate, 10)) {
        std::fputs("fine fixed-view drag calculation failed\n", stderr);
        return 1;
    }
    const quint64 sixSecondsBack = latest - WaveView::groupsForMilliseconds(rate, 6000);
    if (WaveView::canUseFineHistory(sixSecondsBack, latest, rate, 10)) {
        std::fputs("fine history boundary failed\n", stderr);
        return 1;
    }
    const quint64 clamped = WaveView::clampViewEnd(0, latest, tenMsGroups,
        WaveView::groupsForMilliseconds(rate, AdcDisplay::kMaximumHistorySeconds * 1000));
    if (clamped > latest || clamped < tenMsGroups - 1) {
        std::fputs("fixed-view history boundary clamp failed\n", stderr);
        return 1;
    }
    return 0;
}
