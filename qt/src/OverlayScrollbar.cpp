#include "OverlayScrollbar.h"

#include <algorithm>

#include <QEnterEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPropertyAnimation>
#include <QTimer>

namespace {
constexpr int kMargin = 3;        // handle inset from the strip edges
constexpr int kMinHandle = 36;    // minimum handle height
constexpr int kIdleWidth = 6;     // handle width when idle
constexpr int kHoverWidth = 9;    // handle width when hovered
constexpr int kHideDelayMs = 1400;
}  // namespace

OverlayScrollbar::OverlayScrollbar(QWidget *parent) : QWidget(parent) {
  setMouseTracking(true);

  m_fade = new QPropertyAnimation(this, "opacity", this);
  connect(m_fade, &QPropertyAnimation::finished, this, [this]() {
    if (m_opacity <= 0.0) hide();
  });

  m_hideTimer = new QTimer(this);
  m_hideTimer->setSingleShot(true);
  m_hideTimer->setInterval(kHideDelayMs);
  connect(m_hideTimer, &QTimer::timeout, this, [this]() {
    if (m_dragging || m_hover) {
      m_hideTimer->start();  // still in use — check again later
      return;
    }
    fadeTo(0.0, 280);
  });
  hide();
}

void OverlayScrollbar::setOpacity(qreal o) {
  o = std::clamp(o, 0.0, 1.0);
  if (o == m_opacity) return;
  m_opacity = o;
  update();
}

void OverlayScrollbar::setHandleColor(const QColor &color) {
  if (color == m_handleColor) return;
  m_handleColor = color;
  update();
}

void OverlayScrollbar::setMetrics(quint64 total, quint64 offset,
                                  quint64 len) {
  m_total = total;
  m_offset = offset;
  m_len = len;
  // Repaint when visible OR while a fade-out is in flight; the handle
  // position changes constantly with output, and skipping the update
  // makes the fading scrollbar lag behind the actual scrollback.
  if (isVisible() || m_opacity > 0.0) update();
}

void OverlayScrollbar::fadeTo(qreal target, int ms) {
  m_fade->stop();
  m_fade->setDuration(ms);
  m_fade->setStartValue(m_opacity);
  m_fade->setEndValue(target);
  m_fade->start();
}

void OverlayScrollbar::reveal() {
  if (m_total <= m_len) return;  // nothing to scroll
  show();
  raise();
  fadeTo(1.0, 110);
  m_hideTimer->start();
}

QRect OverlayScrollbar::handleRect() const {
  if (m_total <= m_len) return {};
  const int trackH = height() - 2 * kMargin;
  if (trackH <= 0) return {};

  int handleH = static_cast<int>(static_cast<double>(trackH) * m_len /
                                 static_cast<double>(m_total));
  handleH = std::clamp(handleH, std::min(kMinHandle, trackH), trackH);

  const quint64 scrollable = m_total - m_len;
  const int travel = trackH - handleH;
  const int handleY =
      kMargin + (scrollable ? static_cast<int>(static_cast<double>(travel) *
                                               m_offset / scrollable)
                            : 0);

  const int w = m_hover || m_dragging ? kHoverWidth : kIdleWidth;
  return QRect(width() - w - kMargin, handleY, w, handleH);
}

void OverlayScrollbar::paintEvent(QPaintEvent *) {
  if (m_opacity <= 0.0) return;
  const QRect handle = handleRect();
  if (handle.isEmpty()) return;

  QPainter painter(this);
  painter.setRenderHint(QPainter::Antialiasing, true);
  QColor c = m_handleColor;
  // Idle is fairly subtle; hover/drag brighten it. The fade scales it all.
  const qreal base = m_dragging ? 0.80 : m_hover ? 0.62 : 0.42;
  c.setAlphaF(base * m_opacity);
  painter.setPen(Qt::NoPen);
  painter.setBrush(c);
  const qreal radius = handle.width() / 2.0;
  painter.drawRoundedRect(handle, radius, radius);
}

void OverlayScrollbar::emitRowForHandleTop(int top) {
  if (m_total <= m_len) return;
  const int trackH = height() - 2 * kMargin;
  const int travel = trackH - handleRect().height();
  double frac = travel > 0
                    ? static_cast<double>(top - kMargin) / travel
                    : 0.0;
  frac = std::clamp(frac, 0.0, 1.0);
  emit scrollToRow(static_cast<int>(frac * (m_total - m_len)));
}

void OverlayScrollbar::mousePressEvent(QMouseEvent *ev) {
  if (ev->button() != Qt::LeftButton || m_total <= m_len) {
    ev->ignore();
    return;
  }
  const QPoint pos = ev->position().toPoint();
  const QRect handle = handleRect();
  if (handle.contains(pos)) {
    m_dragging = true;
    m_dragGrab = pos.y() - handle.top();
  } else {
    // Trough click: page toward the cursor.
    const qint64 page = static_cast<qint64>(m_len);
    qint64 row = static_cast<qint64>(m_offset) +
                 (pos.y() < handle.top() ? -page : page);
    row = std::clamp<qint64>(row, 0,
                             static_cast<qint64>(m_total - m_len));
    emit scrollToRow(static_cast<int>(row));
  }
  m_hideTimer->start();
  update();
}

void OverlayScrollbar::mouseMoveEvent(QMouseEvent *ev) {
  if (!m_dragging) return;
  emitRowForHandleTop(ev->position().toPoint().y() - m_dragGrab);
  m_hideTimer->start();
}

void OverlayScrollbar::mouseReleaseEvent(QMouseEvent *) {
  m_dragging = false;
  m_hideTimer->start();
  update();
}

void OverlayScrollbar::enterEvent(QEnterEvent *) {
  m_hover = true;
  reveal();  // re-reveal in case it was mid fade-out
  update();
}

void OverlayScrollbar::leaveEvent(QEvent *) {
  m_hover = false;
  m_hideTimer->start();
  update();
}
