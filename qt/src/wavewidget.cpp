#include "wavewidget.h"
#include "waveviewmath.h"

#include <QCheckBox>
#include <QComboBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QMouseEvent>
#include <QPainter>
#include <QPushButton>
#include <QScrollArea>
#include <QWheelEvent>
#include <QVBoxLayout>
#include <algorithm>
#include <cstdlib>
#include <limits>

namespace {
const std::array<QColor, 24> kChannelColors = {
    QColor(0, 220, 255),   // CH00: Cyan
    QColor(255, 204, 0),   // CH01: Yellow
    QColor(70, 235, 120),  // CH02: Green
    QColor(255, 105, 180), // CH03: Hot Pink
    QColor(255, 150, 30),  // CH04: Orange
    QColor(165, 130, 255), // CH05: Purple
    QColor(0, 255, 190),   // CH06: Mint
    QColor(255, 90, 90),   // CH07: Red
    QColor(135, 206, 250), // CH08: Sky Blue
    QColor(240, 230, 90),  // CH09: Lemon
    QColor(110, 255, 160), // CH10: Light Green
    QColor(255, 160, 210), // CH11: Light Pink
    QColor(255, 180, 80),  // CH12: Amber
    QColor(190, 150, 255), // CH13: Violet
    QColor(90, 225, 240),  // CH14: Teal
    QColor(255, 125, 125), // CH15: Coral
    QColor(175, 255, 90),  // CH16: Lime
    QColor(255, 220, 130), // CH17: Gold
    QColor(140, 190, 255), // CH18: Periwinkle
    QColor(255, 140, 170), // CH19: Salmon
    QColor(120, 255, 220), // CH20: Aquamarine
    QColor(220, 170, 255), // CH21: Orchid
    QColor(255, 245, 140), // CH22: Champagne
    QColor(160, 255, 180)  // CH23: Pale Green
};

QString timeLabel(qint64 milliseconds) {
    if (milliseconds == 0) return QStringLiteral("0 s");
    const qint64 magnitude = std::abs(milliseconds);
    if (magnitude < 1000) {
        return QStringLiteral("-%1 ms").arg(magnitude);
    }
    if (magnitude < 60 * 1000) {
        return QStringLiteral("-%1 s").arg(QString::number(double(magnitude) / 1000.0, 'f',
                                                           magnitude % 1000 ? 1 : 0));
    }
    return QStringLiteral("-%1:%2")
        .arg(magnitude / (60 * 1000))
        .arg((magnitude / 1000) % 60, 2, 10, QLatin1Char('0'));
}

QString durationLabel(quint64 milliseconds) {
    if (milliseconds < 1000) return QStringLiteral("%1 ms").arg(milliseconds);
    if (milliseconds < 60 * 1000) {
        return QStringLiteral("%1 s").arg(QString::number(double(milliseconds) / 1000.0, 'f',
                                                           milliseconds % 1000 ? 1 : 0));
    }
    return QStringLiteral("%1:%2")
        .arg(milliseconds / (60 * 1000))
        .arg((milliseconds / 1000) % 60, 2, 10, QLatin1Char('0'));
}
}

// ==================== SingleWavePlot ====================

SingleWavePlot::SingleWavePlot(QWidget *parent) : QWidget(parent) {
    setMinimumHeight(82);
    setAutoFillBackground(false);
    setCursor(Qt::OpenHandCursor);
}

void SingleWavePlot::setChannelInfo(int channel, const QColor &color) {
    m_channel = channel;
    m_color = color;
    update();
}

void SingleWavePlot::setData(const QVector<WaveEnvelopePoint> &data, const ChannelSnapshot &stats,
                             bool enabled, int windowMilliseconds) {
    m_data = data;
    m_stats = stats;
    m_enabled = enabled;
    m_windowMilliseconds = windowMilliseconds;
    update();
}

void SingleWavePlot::setScaleMode(int mode) {
    m_scaleMode = mode;
    update();
}

void SingleWavePlot::setWindowMilliseconds(int milliseconds) {
    m_windowMilliseconds = std::max(1, milliseconds);
    update();
}

void SingleWavePlot::setViewContext(quint64 latestGroupIndex, quint64 viewEndGroupIndex,
                                    quint32 sampleRate, bool followsLatest, bool usesFineHistory) {
    m_latestGroupIndex = latestGroupIndex;
    m_viewEndGroupIndex = viewEndGroupIndex;
    m_sampleRate = sampleRate;
    m_followsLatest = followsLatest;
    m_usesFineHistory = usesFineHistory;
    update();
}

void SingleWavePlot::wheelEvent(QWheelEvent *event) {
    if (event->angleDelta().y() == 0) {
        event->ignore();
        return;
    }
    // Keep the right edge at “now”; the requested change only alters the
    // visible time span and therefore preserves the sampling-time axis.
    emit zoomRequested(event->angleDelta().y() > 0 ? +1 : -1);
    event->accept();
}

void SingleWavePlot::mousePressEvent(QMouseEvent *event) {
    const QRect plot = rect().adjusted(46, 6, -10, -22);
    if (event->button() != Qt::LeftButton || !plot.contains(event->position().toPoint()) ||
        m_sampleRate == 0 || m_data.isEmpty()) {
        event->ignore();
        return;
    }
    m_dragging = true;
    m_dragStartX = event->position().toPoint().x();
    m_dragStartEndGroupIndex = m_viewEndGroupIndex;
    grabMouse();
    setCursor(Qt::ClosedHandCursor);
    event->accept();
}

void SingleWavePlot::mouseMoveEvent(QMouseEvent *event) {
    if (!m_dragging) {
        event->ignore();
        return;
    }
    const QRect plot = rect().adjusted(46, 6, -10, -22);
    const qint64 leftwardPixels = qint64(m_dragStartX) - event->position().toPoint().x();
    quint64 candidate = WaveView::draggedViewEnd(m_dragStartEndGroupIndex, leftwardPixels,
                                                  plot.width(), m_windowMilliseconds, m_sampleRate);
    candidate = std::min(candidate, m_latestGroupIndex);
    if (candidate != m_viewEndGroupIndex) {
        m_viewEndGroupIndex = candidate;
        m_followsLatest = candidate == m_latestGroupIndex;
        emit viewAnchorRequested(candidate);
        update();
    }
    event->accept();
}

void SingleWavePlot::mouseReleaseEvent(QMouseEvent *event) {
    if (m_dragging && event->button() == Qt::LeftButton) {
        m_dragging = false;
        releaseMouse();
        setCursor(Qt::OpenHandCursor);
        event->accept();
        return;
    }
    event->ignore();
}

void SingleWavePlot::paintEvent(QPaintEvent *) {
    QPainter painter(this);
    painter.fillRect(rect(), QColor(16, 20, 26));

    const QRect plot = rect().adjusted(46, 6, -10, -22);
    painter.fillRect(plot, QColor(20, 25, 33));
    painter.setPen(QColor(42, 50, 62));
    painter.drawRect(plot);

    // 0V 基准中心线（实线高亮）
    const int yZero = plot.center().y();
    painter.setPen(QPen(QColor(62, 80, 102), 1, Qt::SolidLine));
    painter.drawLine(plot.left(), yZero, plot.right(), yZero);

    // 辅助水平网格线（四分之一与四分之三虚线）
    painter.setPen(QPen(QColor(36, 46, 58), 1, Qt::DashLine));
    const int yQuarter1 = plot.top() + plot.height() / 4;
    const int yQuarter3 = plot.top() + (3 * plot.height()) / 4;
    painter.drawLine(plot.left(), yQuarter1, plot.right(), yQuarter1);
    painter.drawLine(plot.left(), yQuarter3, plot.right(), yQuarter3);

    // 垂直网格线与真实时间刻度（左端为窗口起点，右端为当前）。
    constexpr int kTimeDivisions = 6;
    for (int div = 1; div < kTimeDivisions; ++div) {
        const int x = plot.left() + (div * plot.width()) / kTimeDivisions;
        painter.drawLine(x, plot.top(), x, plot.bottom());
    }

    // 左侧量程刻度标签
    painter.setFont(QFont(QStringLiteral("Segoe UI"), 8));
    painter.setPen(QColor(135, 148, 165));
    QString topLabel, midLabel = QStringLiteral(" 0V"), botLabel;
    switch (m_scaleMode) {
    case Scale_5V:
        topLabel = QStringLiteral("+5V");
        botLabel = QStringLiteral("-5V");
        break;
    case Scale_2_5V:
        topLabel = QStringLiteral("+2.5V");
        botLabel = QStringLiteral("-2.5V");
        break;
    case Scale_1V:
        topLabel = QStringLiteral("+1V");
        botLabel = QStringLiteral("-1V");
        break;
    case Scale_Auto:
        topLabel = QStringLiteral("Max");
        midLabel = QStringLiteral("Mid");
        botLabel = QStringLiteral("Min");
        break;
    case Scale_10V:
    default:
        topLabel = QStringLiteral("+10V");
        botLabel = QStringLiteral("-10V");
        break;
    }
    painter.drawText(QRect(0, plot.top() - 2, 42, 14), Qt::AlignRight | Qt::AlignVCenter, topLabel);
    painter.drawText(QRect(0, yZero - 7, 42, 14), Qt::AlignRight | Qt::AlignVCenter, midLabel);
    painter.drawText(QRect(0, plot.bottom() - 12, 42, 14), Qt::AlignRight | Qt::AlignVCenter, botLabel);

    painter.setPen(QColor(115, 132, 150));
    painter.setFont(QFont(QStringLiteral("Segoe UI"), 7));
    const quint64 viewAgeMilliseconds = m_sampleRate && m_latestGroupIndex >= m_viewEndGroupIndex
        ? ((m_latestGroupIndex - m_viewEndGroupIndex) * 1000u) / m_sampleRate : 0;
    for (int div = 0; div <= kTimeDivisions; ++div) {
        const int x = plot.left() + (div * plot.width()) / kTimeDivisions;
        const qint64 milliseconds = -(qint64(viewAgeMilliseconds) +
            (qint64(kTimeDivisions - div) * m_windowMilliseconds) / kTimeDivisions);
        const QRect labelRect(x - 28, plot.bottom() + 3, 56, 13);
        painter.drawText(labelRect, Qt::AlignHCenter | Qt::AlignTop, timeLabel(milliseconds));
    }
    painter.drawText(QRect(plot.left(), rect().bottom() - 13, plot.width(), 12),
                     Qt::AlignHCenter | Qt::AlignBottom, QStringLiteral("时间（距当前）"));

    if (!m_enabled) {
        painter.setPen(QColor(85, 98, 115));
        painter.drawText(plot, Qt::AlignCenter, QStringLiteral("通道未勾选（点击左侧开启）"));
        return;
    }

    if (m_data.isEmpty()) {
        painter.setPen(QColor(110, 125, 145));
        painter.drawText(plot, Qt::AlignCenter, QStringLiteral("等待采样数据..."));
        return;
    }

    // 确定当前显示量程。量程选择仅缩放纵轴，物理电压换算始终使用±10 V。
    qint32 minCode = -32768;
    qint32 maxCode = 32767;
    switch (m_scaleMode) {
    case Scale_5V:
        minCode = -16384;
        maxCode = 16383;
        break;
    case Scale_2_5V:
        minCode = -8192;
        maxCode = 8191;
        break;
    case Scale_1V:
        minCode = -3277;
        maxCode = 3277;
        break;
    case Scale_Auto: {
        bool haveValue = false;
        for (const auto &point : m_data) {
            if (!point.valid) continue;
            if (!haveValue) {
                minCode = point.minimum;
                maxCode = point.maximum;
                haveValue = true;
            } else {
                minCode = std::min<qint32>(minCode, point.minimum);
                maxCode = std::max<qint32>(maxCode, point.maximum);
            }
        }
        if (minCode == maxCode) {
            --minCode;
            ++maxCode;
        }
        break;
    }
    case Scale_10V:
    default:
        minCode = -32768;
        maxCode = 32767;
        break;
    }

    const auto mapY = [&](qint16 v) -> int {
        if (maxCode <= minCode) return plot.center().y();
        const double norm = double(v - minCode) / double(maxCode - minCode);
        const int y = int(plot.bottom() - norm * plot.height());
        return std::clamp(y, plot.top(), plot.bottom());
    };

    // 按接收线程给出的时间包络绘制；无有效数据的时间段保留为间隙。
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setPen(QPen(m_color, 1.2));
    const int w = plot.width();
    int lastY = -1;
    for (int x = 0; x < w; ++x) {
        const int i0 = (x * int(m_data.size())) / w;
        const int i1 = std::min(int(m_data.size()), std::max(i0 + 1, ((x + 1) * int(m_data.size())) / w));
        qint16 lo = std::numeric_limits<qint16>::max();
        qint16 hi = std::numeric_limits<qint16>::min();
        bool valid = false;
        for (int i = i0; i < i1; ++i) {
            if (!m_data[i].valid) continue;
            valid = true;
            lo = std::min(lo, m_data[i].minimum);
            hi = std::max(hi, m_data[i].maximum);
        }
        if (!valid) {
            lastY = -1;
            continue;
        }
        const int y1 = mapY(hi);
        const int y2 = mapY(lo);
        if (lastY >= 0) {
            painter.drawLine(plot.left() + x - 1, lastY, plot.left() + x, (y1 + y2) / 2);
        }
        if (y1 != y2) {
            painter.drawLine(plot.left() + x, y1, plot.left() + x, y2);
        }
        lastY = (y1 + y2) / 2;
    }
    painter.setRenderHint(QPainter::Antialiasing, false);

    // 右上角显示最近一个采样值及固定近10分钟范围，不使用累计均值。
    if (m_stats.hasLatest) {
        const QString current = QStringLiteral("当前: %1 V")
            .arg(QString::asprintf("%+.4f", AdcDisplay::codeToVolts(m_stats.latest)));
        QString recent;
        if (m_stats.hasRecent) {
            const double minV = AdcDisplay::codeToVolts(m_stats.recentMinimum);
            const double maxV = AdcDisplay::codeToVolts(m_stats.recentMaximum);
            const double vpp = maxV - minV;
            recent = QStringLiteral("近10分: [%1, %2] V  Vpp %3 V")
                .arg(QString::number(minV, 'f', 2))
                .arg(QString::number(maxV, 'f', 2))
                .arg(QString::number(vpp, 'f', 3));
        }
        painter.setPen(QColor(125, 140, 160));
        painter.setFont(QFont(QStringLiteral("Segoe UI"), 8));
        painter.drawText(plot.adjusted(0, 3, -6, 0), Qt::AlignTop | Qt::AlignRight, current);
        painter.drawText(plot.adjusted(0, 17, -6, 0), Qt::AlignTop | Qt::AlignRight, recent);
    }
}

// ==================== WaveRowWidget ====================

WaveRowWidget::WaveRowWidget(int channel, const QColor &color, QWidget *parent)
    : QWidget(parent), m_channel(channel) {
    setFixedHeight(104);
    auto *layout = new QHBoxLayout(this);
    layout->setContentsMargins(4, 2, 4, 2);
    layout->setSpacing(6);

    // 左侧面板：复选框 + 通道名 + 最近采样电压 + 近10分钟范围。
    auto *infoWidget = new QWidget(this);
    infoWidget->setFixedWidth(155);
    infoWidget->setStyleSheet(QStringLiteral("background-color: #1a2029; border-radius: 4px;"));
    auto *infoLayout = new QVBoxLayout(infoWidget);
    infoLayout->setContentsMargins(8, 4, 8, 4);
    infoLayout->setSpacing(2);

    auto *headerLayout = new QHBoxLayout;
    headerLayout->setContentsMargins(0, 0, 0, 0);
    headerLayout->setSpacing(6);

    m_checkBox = new QCheckBox(this);
    m_nameLabel = new QLabel(QStringLiteral("CH%1").arg(channel, 2, 10, QLatin1Char('0')), this);
    m_nameLabel->setStyleSheet(QStringLiteral("font-weight: bold; font-size: 13px; color: %1;").arg(color.name()));
    headerLayout->addWidget(m_checkBox);
    headerLayout->addWidget(m_nameLabel);
    headerLayout->addStretch();
    infoLayout->addLayout(headerLayout);

    m_realtimeLabel = new QLabel(QStringLiteral("实时: —"), this);
    m_realtimeLabel->setStyleSheet(QStringLiteral("font-size: 10px; color: #ccd6e0;"));
    m_rangeLabel = new QLabel(QStringLiteral("近10分: —"), this);
    m_rangeLabel->setStyleSheet(QStringLiteral("font-size: 9px; color: #aab7c5;"));
    m_statLabel = new QLabel(QStringLiteral("峰峰: —"), this);
    m_statLabel->setStyleSheet(QStringLiteral("font-size: 9px; color: #8c9ba8;"));
    infoLayout->addWidget(m_realtimeLabel);
    infoLayout->addWidget(m_rangeLabel);
    infoLayout->addWidget(m_statLabel);

    layout->addWidget(infoWidget);

    // 右侧绘图部件
    m_plot = new SingleWavePlot(this);
    m_plot->setChannelInfo(channel, color);
    layout->addWidget(m_plot, 1);

    connect(m_checkBox, &QCheckBox::toggled, this, [this](bool checked) {
        emit rowToggled(m_channel, checked);
    });
    connect(m_plot, &SingleWavePlot::zoomRequested, this, &WaveRowWidget::zoomRequested);
    connect(m_plot, &SingleWavePlot::viewAnchorRequested, this, &WaveRowWidget::viewAnchorRequested);
}

bool WaveRowWidget::isChecked() const {
    return m_checkBox->isChecked();
}

void WaveRowWidget::setChecked(bool checked) {
    m_checkBox->setChecked(checked);
}

void WaveRowWidget::updateData(const QVector<WaveEnvelopePoint> &data, const ChannelSnapshot &stats,
                               bool enabled, int windowMilliseconds) {
    if (stats.hasLatest) {
        m_realtimeLabel->setText(QStringLiteral("实时: %1 V")
            .arg(QString::asprintf("%+.4f", AdcDisplay::codeToVolts(stats.latest))));
    } else {
        m_realtimeLabel->setText(QStringLiteral("实时: —"));
    }
    if (stats.hasRecent) {
        const double minV = AdcDisplay::codeToVolts(stats.recentMinimum);
        const double maxV = AdcDisplay::codeToVolts(stats.recentMaximum);
        m_rangeLabel->setText(QStringLiteral("近10分: [%1, %2]V")
            .arg(QString::number(minV, 'f', 2)).arg(QString::number(maxV, 'f', 2)));
        m_statLabel->setText(QStringLiteral("峰峰: %1 V").arg(QString::number(maxV - minV, 'f', 3)));
    } else {
        m_rangeLabel->setText(QStringLiteral("近10分: —"));
        m_statLabel->setText(QStringLiteral("峰峰: —"));
    }
    m_plot->setData(data, stats, enabled, windowMilliseconds);
}

void WaveRowWidget::setScaleMode(int mode) {
    m_plot->setScaleMode(mode);
}

void WaveRowWidget::setWindowMilliseconds(int milliseconds) {
    m_plot->setWindowMilliseconds(milliseconds);
}

void WaveRowWidget::setViewContext(quint64 latestGroupIndex, quint64 viewEndGroupIndex,
                                   quint32 sampleRate, bool followsLatest, bool usesFineHistory) {
    m_plot->setViewContext(latestGroupIndex, viewEndGroupIndex, sampleRate,
                           followsLatest, usesFineHistory);
}

// ==================== WaveWidget ====================

WaveWidget::WaveWidget(QWidget *parent) : QWidget(parent) {
    auto *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);
    mainLayout->setSpacing(4);

    // 顶部工具栏
    auto *toolBar = new QWidget(this);
    auto *toolLayout = new QHBoxLayout(toolBar);
    toolLayout->setContentsMargins(4, 2, 4, 2);
    toolLayout->setSpacing(6);

    auto *titleLabel = new QLabel(QStringLiteral("实时波形（按采样时间滚动）"), this);
    titleLabel->setStyleSheet(QStringLiteral("font-weight: bold; font-size: 12px; color: #e0e6ed;"));
    toolLayout->addWidget(titleLabel);

    auto *btnSelectAll = new QPushButton(QStringLiteral("全选"), this);
    auto *btnDeselectAll = new QPushButton(QStringLiteral("清空"), this);
    auto *btnSelect4 = new QPushButton(QStringLiteral("前4路"), this);
    auto *btnSelect8 = new QPushButton(QStringLiteral("前8路"), this);
    for (auto *btn : {btnSelectAll, btnDeselectAll, btnSelect4, btnSelect8}) {
        btn->setMaximumWidth(55);
        toolLayout->addWidget(btn);
    }

    toolLayout->addSpacing(8);

    m_scaleCombo = new QComboBox(this);
    m_scaleCombo->addItem(QStringLiteral("量程: ±10V (默认)"), SingleWavePlot::Scale_10V);
    m_scaleCombo->addItem(QStringLiteral("量程: ±5V"), SingleWavePlot::Scale_5V);
    m_scaleCombo->addItem(QStringLiteral("量程: ±2.5V"), SingleWavePlot::Scale_2_5V);
    m_scaleCombo->addItem(QStringLiteral("量程: ±1V"), SingleWavePlot::Scale_1V);
    m_scaleCombo->addItem(QStringLiteral("量程: 自适应"), SingleWavePlot::Scale_Auto);
    toolLayout->addWidget(m_scaleCombo);

    m_windowCombo = new QComboBox(this);
    m_windowCombo->addItem(QStringLiteral("时间: 最近1 ms"), 1);
    m_windowCombo->addItem(QStringLiteral("时间: 最近2 ms"), 2);
    m_windowCombo->addItem(QStringLiteral("时间: 最近5 ms"), 5);
    m_windowCombo->addItem(QStringLiteral("时间: 最近10 ms"), 10);
    m_windowCombo->addItem(QStringLiteral("时间: 最近20 ms"), 20);
    m_windowCombo->addItem(QStringLiteral("时间: 最近50 ms"), 50);
    m_windowCombo->addItem(QStringLiteral("时间: 最近100 ms"), 100);
    m_windowCombo->addItem(QStringLiteral("时间: 最近200 ms"), 200);
    m_windowCombo->addItem(QStringLiteral("时间: 最近500 ms"), 500);
    m_windowCombo->addItem(QStringLiteral("时间: 最近1秒"), 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近2秒"), 2 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近5秒"), 5 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近10秒"), 10 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近30秒"), 30 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近1分钟"), 60 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近2分钟"), 2 * 60 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近5分钟"), 5 * 60 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近10分钟"), 10 * 60 * 1000);
    m_windowCombo->addItem(QStringLiteral("时间: 最近30分钟"), 30 * 60 * 1000);
    m_windowCombo->setCurrentIndex(14);
    toolLayout->addWidget(m_windowCombo);

    auto *btnZoomIn = new QPushButton(QStringLiteral("横轴 +"), this);
    auto *btnZoomOut = new QPushButton(QStringLiteral("横轴 −"), this);
    btnZoomIn->setToolTip(QStringLiteral("缩短显示时间范围（放大横轴）"));
    btnZoomOut->setToolTip(QStringLiteral("延长显示时间范围（缩小横轴）"));
    toolLayout->addWidget(btnZoomIn);
    toolLayout->addWidget(btnZoomOut);
    auto *zoomHint = new QLabel(QStringLiteral("鼠标滚轮也可缩放横轴"), this);
    zoomHint->setStyleSheet(QStringLiteral("color: #8c9ba8; font-size: 10px;"));
    toolLayout->addWidget(zoomHint);

    m_returnLatestButton = new QPushButton(QStringLiteral("回到最新"), this);
    m_returnLatestButton->setToolTip(QStringLiteral("恢复波形右端跟随最新采样时刻"));
    m_returnLatestButton->setEnabled(false);
    toolLayout->addWidget(m_returnLatestButton);
    m_viewStatusLabel = new QLabel(QStringLiteral("实时跟随"), this);
    m_viewStatusLabel->setStyleSheet(QStringLiteral("color: #8c9ba8; font-size: 10px;"));
    toolLayout->addWidget(m_viewStatusLabel);

    toolLayout->addStretch();
    mainLayout->addWidget(toolBar);

    // 滚动区域容纳24个通道行
    m_scrollArea = new QScrollArea(this);
    m_scrollArea->setWidgetResizable(true);
    m_scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);

    auto *container = new QWidget;
    auto *rowsLayout = new QVBoxLayout(container);
    rowsLayout->setContentsMargins(2, 2, 2, 2);
    rowsLayout->setSpacing(3);

    for (int ch = 0; ch < 24; ++ch) {
        m_rows[ch] = new WaveRowWidget(ch, kChannelColors[ch], container);
        rowsLayout->addWidget(m_rows[ch]);
        connect(m_rows[ch], &WaveRowWidget::rowToggled, this, &WaveWidget::onRowToggled);
        connect(m_rows[ch], &WaveRowWidget::zoomRequested, this, &WaveWidget::onZoomRequested);
        connect(m_rows[ch], &WaveRowWidget::viewAnchorRequested, this, &WaveWidget::onViewAnchorRequested);
    }
    rowsLayout->addStretch();
    m_scrollArea->setWidget(container);
    mainLayout->addWidget(m_scrollArea, 1);

    connect(btnSelectAll, &QPushButton::clicked, this, &WaveWidget::onSelectAll);
    connect(btnDeselectAll, &QPushButton::clicked, this, &WaveWidget::onDeselectAll);
    connect(btnSelect4, &QPushButton::clicked, this, &WaveWidget::onSelectFirst4);
    connect(btnSelect8, &QPushButton::clicked, this, &WaveWidget::onSelectFirst8);
    connect(m_scaleCombo, qOverload<int>(&QComboBox::currentIndexChanged), this, &WaveWidget::onScaleChanged);
    connect(m_windowCombo, qOverload<int>(&QComboBox::currentIndexChanged), this, &WaveWidget::onWindowChanged);
    connect(btnZoomIn, &QPushButton::clicked, this, [this] { onZoomRequested(+1); });
    connect(btnZoomOut, &QPushButton::clicked, this, [this] { onZoomRequested(-1); });
    connect(m_returnLatestButton, &QPushButton::clicked, this, &WaveWidget::onReturnLatest);

    // 初始默认勾选前4路
    m_blockSignals = true;
    for (int ch = 0; ch < 24; ++ch) {
        m_rows[ch]->setChecked(ch < 4);
    }
    m_blockSignals = false;
}

void WaveWidget::setSnapshot(const MonitorSnapshot &snapshot) {
    m_latestGroupIndex = snapshot.latestGroupIndex;
    m_viewEndGroupIndex = snapshot.viewEndGroupIndex;
    m_sampleRate = snapshot.waveSampleRate;
    m_waveFollowsLatest = snapshot.waveFollowsLatest;
    m_waveUsesFineHistory = snapshot.waveUsesFineHistory;
    updateViewStatus();
    for (int ch = 0; ch < 24; ++ch) {
        m_rows[ch]->updateData(snapshot.waves[ch], snapshot.channels[ch], snapshot.waveEnabled[ch],
                               snapshot.waveWindowMilliseconds);
    }
    updateRowsViewContext();
}

QVector<int> WaveWidget::selectedChannels() const {
    QVector<int> result;
    for (int ch = 0; ch < 24; ++ch) {
        if (m_rows[ch]->isChecked()) {
            result.push_back(ch);
        }
    }
    return result;
}

void WaveWidget::setSelectedChannels(const QVector<int> &channels) {
    m_blockSignals = true;
    for (int ch = 0; ch < 24; ++ch) {
        m_rows[ch]->setChecked(channels.contains(ch));
    }
    m_blockSignals = false;
    emit waveSelectionChanged(selectedChannels());
}

void WaveWidget::setChannelChecked(int channel, bool checked) {
    if (channel >= 0 && channel < 24) {
        m_rows[channel]->setChecked(checked);
    }
}

int WaveWidget::windowMilliseconds() const {
    return m_windowCombo->currentData().toInt();
}

void WaveWidget::onRowToggled(int, bool) {
    if (!m_blockSignals) {
        emit waveSelectionChanged(selectedChannels());
    }
}

void WaveWidget::onSelectAll() {
    m_blockSignals = true;
    for (int ch = 0; ch < 24; ++ch) m_rows[ch]->setChecked(true);
    m_blockSignals = false;
    emit waveSelectionChanged(selectedChannels());
}

void WaveWidget::onDeselectAll() {
    m_blockSignals = true;
    for (int ch = 0; ch < 24; ++ch) m_rows[ch]->setChecked(false);
    m_blockSignals = false;
    emit waveSelectionChanged(selectedChannels());
}

void WaveWidget::onSelectFirst4() {
    m_blockSignals = true;
    for (int ch = 0; ch < 24; ++ch) m_rows[ch]->setChecked(ch < 4);
    m_blockSignals = false;
    emit waveSelectionChanged(selectedChannels());
}

void WaveWidget::onSelectFirst8() {
    m_blockSignals = true;
    for (int ch = 0; ch < 24; ++ch) m_rows[ch]->setChecked(ch < 8);
    m_blockSignals = false;
    emit waveSelectionChanged(selectedChannels());
}

void WaveWidget::onScaleChanged(int) {
    const int mode = m_scaleCombo->currentData().toInt();
    for (int ch = 0; ch < 24; ++ch) {
        m_rows[ch]->setScaleMode(mode);
    }
}

void WaveWidget::onWindowChanged(int) {
    const int milliseconds = windowMilliseconds();
    for (auto *row : m_rows) {
        row->setWindowMilliseconds(milliseconds);
    }
    emit waveWindowChanged(milliseconds);
}

void WaveWidget::onZoomRequested(int direction) {
    const int current = m_windowCombo->currentIndex();
    // Entries are ordered from short to long: +1 means zoom in.
    const int next = std::clamp(current - direction, 0, m_windowCombo->count() - 1);
    if (next != current) {
        m_windowCombo->setCurrentIndex(next);
    }
}

void WaveWidget::onViewAnchorRequested(quint64 endGroupIndex) {
    m_viewEndGroupIndex = std::min(endGroupIndex, m_latestGroupIndex);
    m_waveFollowsLatest = m_viewEndGroupIndex == m_latestGroupIndex;
    updateViewStatus();
    updateRowsViewContext();
    emit waveViewAnchorChanged(m_viewEndGroupIndex);
}

void WaveWidget::onReturnLatest() {
    m_viewEndGroupIndex = m_latestGroupIndex;
    m_waveFollowsLatest = true;
    updateViewStatus();
    updateRowsViewContext();
    emit waveFollowLatestRequested();
}

void WaveWidget::updateViewStatus() {
    if (!m_viewStatusLabel || !m_returnLatestButton) return;
    if (m_waveFollowsLatest || m_sampleRate == 0) {
        m_viewStatusLabel->setText(QStringLiteral("实时跟随"));
        m_returnLatestButton->setEnabled(false);
        return;
    }
    const quint64 elapsedGroups = m_latestGroupIndex >= m_viewEndGroupIndex
        ? m_latestGroupIndex - m_viewEndGroupIndex : 0;
    const quint64 elapsedMilliseconds = (elapsedGroups * 1000u) / m_sampleRate;
    QString text = QStringLiteral("固定查看：距最新 %1").arg(durationLabel(elapsedMilliseconds));
    if (!m_waveUsesFineHistory) {
        text += QStringLiteral(" · 历史包络（10 ms）");
    }
    m_viewStatusLabel->setText(text);
    m_returnLatestButton->setEnabled(true);
}

void WaveWidget::updateRowsViewContext() {
    for (auto *row : m_rows) {
        row->setViewContext(m_latestGroupIndex, m_viewEndGroupIndex, m_sampleRate,
                            m_waveFollowsLatest, m_waveUsesFineHistory);
    }
}
