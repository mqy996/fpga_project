#pragma once

#include "dataworker.h"

#include <QWidget>
#include <QVector>
#include <array>

class QCheckBox;
class QComboBox;
class QLabel;
class QPushButton;
class QScrollArea;
class QWheelEvent;
class QMouseEvent;

class SingleWavePlot final : public QWidget {
    Q_OBJECT
public:
    enum ScaleMode {
        Scale_10V = 0, // ±10V (默认)
        Scale_5V  = 1, // ±5V
        Scale_2_5V = 2, // ±2.5V
        Scale_1V  = 3, // ±1V
        Scale_Auto = 4  // 自适应
    };

    explicit SingleWavePlot(QWidget *parent = nullptr);
    void setChannelInfo(int channel, const QColor &color);
    void setData(const QVector<WaveEnvelopePoint> &data, const ChannelSnapshot &stats, bool enabled,
                 int windowMilliseconds);
    void setScaleMode(int mode);
    void setWindowMilliseconds(int milliseconds);
    void setViewContext(quint64 latestGroupIndex, quint64 viewEndGroupIndex, quint32 sampleRate,
                        bool followsLatest, bool usesFineHistory);

protected:
    void paintEvent(QPaintEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;

signals:
    // +1 requests a shorter time range (zoom in); -1 requests a longer one.
    void zoomRequested(int direction);
    void viewAnchorRequested(quint64 endGroupIndex);

private:
    int m_channel = 0;
    QColor m_color {0, 220, 255};
    bool m_enabled = false;
    QVector<WaveEnvelopePoint> m_data;
    ChannelSnapshot m_stats {};
    int m_scaleMode = Scale_10V;
    int m_windowMilliseconds = 60 * 1000;
    quint64 m_latestGroupIndex = 0;
    quint64 m_viewEndGroupIndex = 0;
    quint32 m_sampleRate = 0;
    bool m_followsLatest = true;
    bool m_usesFineHistory = false;
    bool m_dragging = false;
    int m_dragStartX = 0;
    quint64 m_dragStartEndGroupIndex = 0;
};

class WaveRowWidget final : public QWidget {
    Q_OBJECT
public:
    explicit WaveRowWidget(int channel, const QColor &color, QWidget *parent = nullptr);
    int channel() const { return m_channel; }
    bool isChecked() const;
    void setChecked(bool checked);
    void updateData(const QVector<WaveEnvelopePoint> &data, const ChannelSnapshot &stats, bool enabled,
                    int windowMilliseconds);
    void setScaleMode(int mode);
    void setWindowMilliseconds(int milliseconds);
    void setViewContext(quint64 latestGroupIndex, quint64 viewEndGroupIndex, quint32 sampleRate,
                        bool followsLatest, bool usesFineHistory);

signals:
    void rowToggled(int channel, bool checked);
    void zoomRequested(int direction);
    void viewAnchorRequested(quint64 endGroupIndex);

private:
    int m_channel = 0;
    QCheckBox *m_checkBox = nullptr;
    QLabel *m_nameLabel = nullptr;
    QLabel *m_realtimeLabel = nullptr;
    QLabel *m_rangeLabel = nullptr;
    QLabel *m_statLabel = nullptr;
    SingleWavePlot *m_plot = nullptr;
};

class WaveWidget final : public QWidget {
    Q_OBJECT
public:
    explicit WaveWidget(QWidget *parent = nullptr);
    void setSnapshot(const MonitorSnapshot &snapshot);
    QVector<int> selectedChannels() const;
    void setSelectedChannels(const QVector<int> &channels);
    void setChannelChecked(int channel, bool checked);
    int windowMilliseconds() const;

signals:
    void waveSelectionChanged(const QVector<int> &channels);
    void waveWindowChanged(int milliseconds);
    void waveViewAnchorChanged(quint64 endGroupIndex);
    void waveFollowLatestRequested();

private slots:
    void onRowToggled(int channel, bool checked);
    void onSelectAll();
    void onDeselectAll();
    void onSelectFirst4();
    void onSelectFirst8();
    void onScaleChanged(int index);
    void onWindowChanged(int index);
    void onZoomRequested(int direction);
    void onViewAnchorRequested(quint64 endGroupIndex);
    void onReturnLatest();

private:
    void updateViewStatus();
    void updateRowsViewContext();
    std::array<WaveRowWidget *, 24> m_rows {};
    QScrollArea *m_scrollArea = nullptr;
    QComboBox *m_scaleCombo = nullptr;
    QComboBox *m_windowCombo = nullptr;
    QLabel *m_viewStatusLabel = nullptr;
    QPushButton *m_returnLatestButton = nullptr;
    quint64 m_latestGroupIndex = 0;
    quint64 m_viewEndGroupIndex = 0;
    quint32 m_sampleRate = 0;
    bool m_waveFollowsLatest = true;
    bool m_waveUsesFineHistory = false;
    bool m_blockSignals = false;
};
