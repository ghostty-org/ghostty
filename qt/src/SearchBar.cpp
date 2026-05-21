#include "SearchBar.h"

#include <QByteArray>
#include <QEvent>
#include <QHBoxLayout>
#include <QIcon>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QPalette>
#include <QTimer>
#include <QToolButton>

#include "GhosttySurface.h"

namespace {
// A themed tool button, icon from the icon theme with a text fallback.
QToolButton *makeButton(QWidget *parent, const QString &iconName,
                        const QString &fallback, const QString &tip) {
  auto *b = new QToolButton(parent);
  const QIcon icon = QIcon::fromTheme(iconName);
  if (icon.isNull())
    b->setText(fallback);
  else
    b->setIcon(icon);
  b->setAutoRaise(true);
  b->setToolTip(tip);
  b->setFocusPolicy(Qt::NoFocus);
  return b;
}
}  // namespace

SearchBar::SearchBar(GhosttySurface *surface)
    : QFrame(surface), m_surface(surface) {
  // A themed panel: the frame, field and buttons follow the active Qt
  // style and palette.
  setFrameShape(QFrame::StyledPanel);
  setAutoFillBackground(true);

  m_field = new QLineEdit(this);
  m_field->setPlaceholderText(QStringLiteral("Find"));
  m_field->setMinimumWidth(200);
  m_field->installEventFilter(this);

  // The match counter lives inside the field, at its right edge, in the
  // muted placeholder-text colour.
  m_count = new QLabel(m_field);
  m_count->setAttribute(Qt::WA_TransparentForMouseEvents);
  QPalette pal = m_count->palette();
  pal.setColor(QPalette::WindowText, pal.color(QPalette::PlaceholderText));
  m_count->setPalette(pal);

  QToolButton *prev = makeButton(this, QStringLiteral("go-up"),
                                 QStringLiteral("▲"),
                                 QStringLiteral("Previous match"));
  QToolButton *next = makeButton(this, QStringLiteral("go-down"),
                                 QStringLiteral("▼"),
                                 QStringLiteral("Next match"));
  QToolButton *close = makeButton(this, QStringLiteral("window-close"),
                                  QStringLiteral("✕"),
                                  QStringLiteral("Close search"));

  auto *layout = new QHBoxLayout(this);
  layout->setContentsMargins(6, 4, 6, 4);
  layout->setSpacing(2);
  layout->addWidget(m_field);
  layout->addWidget(prev);
  layout->addWidget(next);
  layout->addWidget(close);

  // Coalesce keystrokes so a fast typist does not thrash the search.
  m_debounce = new QTimer(this);
  m_debounce->setSingleShot(true);
  m_debounce->setInterval(200);
  connect(m_debounce, &QTimer::timeout, this, &SearchBar::sendQuery);
  connect(m_field, &QLineEdit::textChanged, this,
          [this]() { m_debounce->start(); });
  connect(prev, &QToolButton::clicked, this, [this]() { navigate(false); });
  connect(next, &QToolButton::clicked, this, [this]() { navigate(true); });
  connect(close, &QToolButton::clicked, this, [this]() {
    runAction("end_search");
    hide();
    // m_surface is the parent so it normally outlives the bar, but
    // during a window teardown Qt may deliver this signal mid-cascade.
    if (m_surface) m_surface->setFocus();
  });
  hide();
}

void SearchBar::open(const QString &prefill) {
  m_total = -1;
  m_selected = -1;
  updateCount();
  show();
  raise();
  if (!prefill.isEmpty())
    m_field->setText(prefill);  // textChanged → debounced query
  m_field->setFocus();
  m_field->selectAll();
}

void SearchBar::setTotal(int total) {
  m_total = total;
  updateCount();
}

void SearchBar::setSelected(int selected) {
  m_selected = selected;
  updateCount();
}

void SearchBar::updateCount() {
  QString text;
  if (m_total == 0)
    text = QStringLiteral("No results");
  else if (m_total > 0)
    text = QStringLiteral("%1/%2")
               .arg(m_selected > 0 ? m_selected : 0)
               .arg(m_total);
  m_count->setText(text);
  m_count->adjustSize();
  positionCount();
}

void SearchBar::positionCount() {
  const int pad = 6;
  m_count->move(m_field->width() - m_count->width() - pad,
                (m_field->height() - m_count->height()) / 2);
  // Reserve room so typed text never slides under the counter.
  const int reserve =
      m_count->text().isEmpty() ? 0 : m_count->width() + pad + 2;
  m_field->setTextMargins(0, 0, reserve, 0);
}

void SearchBar::sendQuery() {
  // An empty needle cancels the search, which libghostty handles.
  const QByteArray q =
      QByteArrayLiteral("search:") + m_field->text().toUtf8();
  if (m_surface && m_surface->surface())
    ghostty_surface_binding_action(m_surface->surface(), q.constData(),
                                   q.size());
}

void SearchBar::navigate(bool next) {
  runAction(next ? "navigate_search:next" : "navigate_search:previous");
}

void SearchBar::runAction(const char *action) {
  if (m_surface && m_surface->surface())
    ghostty_surface_binding_action(m_surface->surface(), action,
                                   qstrlen(action));
}

bool SearchBar::eventFilter(QObject *obj, QEvent *event) {
  if (obj == m_field) {
    if (event->type() == QEvent::Resize) {
      positionCount();
    } else if (event->type() == QEvent::KeyPress) {
      auto *ke = static_cast<QKeyEvent *>(event);
      switch (ke->key()) {
        case Qt::Key_Escape:
          runAction("end_search");
          hide();
          if (m_surface) m_surface->setFocus();
          return true;
        case Qt::Key_Return:
        case Qt::Key_Enter:
          // Enter advances; Shift+Enter goes back.
          navigate(!(ke->modifiers() & Qt::ShiftModifier));
          return true;
        default:
          break;
      }
    }
  }
  return QFrame::eventFilter(obj, event);
}
