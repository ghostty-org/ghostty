#include "CommandPalette.h"

#include <QAbstractItemView>
#include <QByteArray>
#include <QEvent>
#include <QKeyEvent>
#include <QLineEdit>
#include <QListView>
#include <QSortFilterProxyModel>
#include <QStandardItemModel>
#include <QVBoxLayout>

#include "GhosttySurface.h"
#include "MainWindow.h"

namespace {
// Item data roles: the keybind action to run, and the text the filter
// matches against (title plus the bare action name).
constexpr int kActionRole = Qt::UserRole;
constexpr int kFilterRole = Qt::UserRole + 1;
}  // namespace

CommandPalette::CommandPalette(QWidget *owner)
    : QWidget(owner, Qt::Popup), m_owner(owner) {
  resize(620, 420);

  m_search = new QLineEdit(this);
  m_search->setPlaceholderText(QStringLiteral("Run a command…"));
  m_search->setClearButtonEnabled(true);
  m_search->installEventFilter(this);

  m_model = new QStandardItemModel(this);
  m_filter = new QSortFilterProxyModel(this);
  m_filter->setSourceModel(m_model);
  m_filter->setFilterRole(kFilterRole);
  m_filter->setFilterCaseSensitivity(Qt::CaseInsensitive);

  m_list = new QListView(this);
  m_list->setModel(m_filter);
  m_list->setEditTriggers(QAbstractItemView::NoEditTriggers);
  m_list->setSelectionMode(QAbstractItemView::SingleSelection);
  m_list->setUniformItemSizes(true);
  m_list->setFocusPolicy(Qt::NoFocus);  // keep typing in the search box

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(8, 8, 8, 8);
  layout->addWidget(m_search);
  layout->addWidget(m_list);

  connect(m_search, &QLineEdit::textChanged, this, [this](const QString &t) {
    m_filter->setFilterFixedString(t);
    selectFirstRow();
  });
  connect(m_list, &QListView::activated, this,
          [this](const QModelIndex &) { runSelected(); });
  hide();
}

void CommandPalette::toggleFor(GhosttySurface *surface) {
  if (isVisible()) {
    hide();
    return;
  }
  m_surface = surface;
  populate();
  m_search->clear();
  m_filter->setFilterFixedString(QString());

  // Centre over the owner, biased toward the top. As a Qt::Popup the
  // position is interpreted relative to the parent window, so this
  // places correctly on Wayland too.
  if (m_owner) {
    const QPoint p((m_owner->width() - width()) / 2, m_owner->height() / 6);
    move(m_owner->mapToGlobal(p));
  }
  show();
  m_search->setFocus();
  selectFirstRow();
}

void CommandPalette::populate() {
  m_model->clear();
  if (!m_surface || !m_surface->owner()) return;
  ghostty_config_t cfg = m_surface->owner()->config();
  if (!cfg) return;

  // command-palette-entry defaults to a large built-in command set.
  ghostty_config_command_list_s list = {};
  if (!ghostty_config_get(cfg, &list, "command-palette-entry",
                          qstrlen("command-palette-entry")))
    return;
  for (size_t i = 0; i < list.len; ++i) {
    const ghostty_command_s &c = list.commands[i];
    const QString title = QString::fromUtf8(c.title ? c.title : "");
    const QString action = QString::fromUtf8(c.action ? c.action : "");
    if (title.isEmpty() || action.isEmpty()) continue;
    auto *item = new QStandardItem(title);
    item->setData(action, kActionRole);
    item->setData(title + QLatin1Char(' ') +
                      QString::fromUtf8(c.action_key ? c.action_key : ""),
                  kFilterRole);
    if (c.description && *c.description)
      item->setToolTip(QString::fromUtf8(c.description));
    m_model->appendRow(item);
  }
}

void CommandPalette::selectFirstRow() {
  if (m_filter->rowCount() > 0)
    m_list->setCurrentIndex(m_filter->index(0, 0));
}

void CommandPalette::moveSelection(int delta) {
  const int n = m_filter->rowCount();
  if (n == 0) return;
  int row = m_list->currentIndex().row();
  row = qBound(0, (row < 0 ? 0 : row) + delta, n - 1);
  m_list->setCurrentIndex(m_filter->index(row, 0));
}

void CommandPalette::runSelected() {
  const QModelIndex idx = m_list->currentIndex();
  if (!idx.isValid()) return;
  const QString action = idx.data(kActionRole).toString();
  GhosttySurface *surface = m_surface;
  hide();  // close before executing, matching the GTK palette
  if (surface && surface->surface() && !action.isEmpty()) {
    const QByteArray a = action.toUtf8();
    ghostty_surface_binding_action(surface->surface(), a.constData(),
                                   a.size());
  }
}

bool CommandPalette::eventFilter(QObject *obj, QEvent *event) {
  if (obj == m_search && event->type() == QEvent::KeyPress) {
    auto *ke = static_cast<QKeyEvent *>(event);
    switch (ke->key()) {
      case Qt::Key_Up: moveSelection(-1); return true;
      case Qt::Key_Down: moveSelection(1); return true;
      case Qt::Key_Return:
      case Qt::Key_Enter: runSelected(); return true;
      case Qt::Key_Escape: hide(); return true;
      default: break;
    }
  }
  return QWidget::eventFilter(obj, event);
}
