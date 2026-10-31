#pragma once

#include "adcmath.h"

#include <QtGlobal>
#include <algorithm>

namespace WaveView {

inline quint64 groupsForMilliseconds(quint32 sampleRate, quint64 milliseconds) {
    if (sampleRate == 0 || milliseconds == 0) return 1;
    return std::max<quint64>(1, (quint64(sampleRate) * milliseconds + 999) / 1000);
}

inline quint64 oldestCompleteWindowEnd(quint64 latestGroup, quint64 windowGroups,
                                       quint64 retainedGroups) {
    if (windowGroups == 0 || retainedGroups < windowGroups || latestGroup + 1 < windowGroups) {
        return latestGroup;
    }
    const quint64 oldestRetained = latestGroup >= retainedGroups ? latestGroup - retainedGroups + 1 : 0;
    return oldestRetained + windowGroups - 1;
}

inline quint64 clampViewEnd(quint64 requestedEnd, quint64 latestGroup, quint64 windowGroups,
                            quint64 retainedGroups) {
    const quint64 minimumEnd = oldestCompleteWindowEnd(latestGroup, windowGroups, retainedGroups);
    return std::clamp(requestedEnd, minimumEnd, latestGroup);
}

inline bool canUseFineHistory(quint64 viewEndGroup, quint64 latestGroup, quint32 sampleRate,
                              quint64 windowMilliseconds) {
    if (sampleRate == 0 || windowMilliseconds > AdcDisplay::kFineHistoryMilliseconds) return false;
    const quint64 fineGroups = groupsForMilliseconds(sampleRate, AdcDisplay::kFineHistoryMilliseconds);
    const quint64 windowGroups = groupsForMilliseconds(sampleRate, windowMilliseconds);
    const quint64 earliestFine = latestGroup >= fineGroups ? latestGroup - fineGroups + 1 : 0;
    return viewEndGroup >= earliestFine + windowGroups - 1;
}

inline quint64 draggedViewEnd(quint64 startEndGroup, qint64 leftwardPixels, int plotWidth,
                              quint64 windowMilliseconds, quint32 sampleRate) {
    if (plotWidth <= 0 || sampleRate == 0) return startEndGroup;
    const qint64 offsetGroups = (leftwardPixels * qint64(windowMilliseconds) * qint64(sampleRate)) /
                                (qint64(plotWidth) * 1000);
    const qint64 candidate = qint64(startEndGroup) - offsetGroups;
    return candidate <= 0 ? 0 : quint64(candidate);
}

} // namespace WaveView
