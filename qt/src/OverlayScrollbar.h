#pragma once

#include <QColor>
#include <QWidget>

class QPropertyAnimation;
class QTimer;

// A thin scrollback scrollbar that floats over the terminal.
//
// Qt's QScrollBar has no overlay/auto-hide mode (unlike the native GTK4
// and AppKit scrollbars the other Ghostty frontends get for free), so
// this is a small purpose-built widget: it custom-paints a rounded-pill
// handle, fades in on scroll activity and out when idle, and expands
// slightly on hover. It is driven by the libghostty SCROLLBAR action.
class OverlayScrollbar : public QWidget {
  Q_OBJECT
  Q_PROPERTY(qreal opacity READ opacity WRITE setOpacity)

public:
  // Logical width of the strip the widget occupies at the window edge.
  static constexpr int kWidth = 16;

  explicit OverlayScrollbar(QWidget *parent);

  // Scrollback metrics from the SCROLLBAR action (rows).
  void setMetrics(quint64 total, quint64 offset, quint64 len);
  // Fade the scrollbar in and (re)arm the idle-hide timer.
  void reveal();
  // Handle colour, typically derived from the terminal background.
  void setHandleColor(const QColor &color);

  qreal opacity() const { return m_opacity; }
  void setOpacity(qreal o);

signals:
  // The user dragged or clicked the scrollbar to this scrollback row.
  void scrollToRow(int row);

protected:
  void paintEvent(QPaintEvent *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void enterEvent(QEnterEvent *) override;
  void leaveEvent(QEvent *) override;

private:
  QRect handleRect() const;        // pixel rect of the handle
  void emitRowForHandleTop(int top);
  void fadeTo(qreal target, int ms);

  quint64 m_total = 0;             // total scrollback rows
  quint64 m_offset = 0;            // viewport-top row
  quint64 m_len = 0;               // visible rows
  qreal m_opacity = 0.0;
  QColor m_handleColor = QColor(235, 235, 235);
  bool m_hover = false;
  bool m_dragging = false;
  int m_dragGrab = 0;              // cursor offset within the handle
  QPropertyAnimation *m_fade = nullptr;
  QTimer *m_hideTimer = nullptr;
};
