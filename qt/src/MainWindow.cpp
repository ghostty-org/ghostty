#include "MainWindow.h"

#include <cstdio>

#include <QByteArray>
#include <QClipboard>
#include <QGuiApplication>
#include <QList>
#include <QSplitter>
#include <QString>
#include <QTabWidget>
#include <QTimer>
#include <QVBoxLayout>

#include "GhosttySurface.h"

MainWindow::MainWindow() {
  setWindowTitle(QStringLiteral("Ghostty (Qt)"));

  m_tabs = new QTabWidget(this);
  m_tabs->setTabsClosable(true);
  m_tabs->setMovable(true);
  m_tabs->setDocumentMode(true);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->addWidget(m_tabs);

  connect(m_tabs, &QTabWidget::tabCloseRequested, this,
          &MainWindow::onTabCloseRequested);
  connect(m_tabs, &QTabWidget::currentChanged, this,
          &MainWindow::onCurrentChanged);
}

MainWindow::~MainWindow() {
  // Surfaces must be destroyed (freeing their ghostty_surface_t and
  // stopping their renderer threads) before the shared app is freed.
  qDeleteAll(m_containers);
  m_containers.clear();
  if (m_app) ghostty_app_free(m_app);
  if (m_config) ghostty_config_free(m_config);
}

bool MainWindow::initialize() {
  // Load configuration in the same order as the reference apprt.
  m_config = ghostty_config_new();
  ghostty_config_load_default_files(m_config);
  ghostty_config_load_cli_args(m_config);
  ghostty_config_load_recursive_files(m_config);
  ghostty_config_finalize(m_config);

  ghostty_runtime_config_s rt = {};
  rt.userdata = this;
  rt.supports_selection_clipboard = true;
  rt.wakeup_cb = onWakeup;
  rt.action_cb = onAction;
  rt.read_clipboard_cb = onReadClipboard;
  rt.confirm_read_clipboard_cb = onConfirmReadClipboard;
  rt.write_clipboard_cb = onWriteClipboard;
  rt.close_surface_cb = onCloseSurface;

  m_app = ghostty_app_new(&rt, m_config);
  if (!m_app) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_app_new failed\n");
    return false;
  }

  // Periodic tick as a backstop; onWakeup drives responsive ticking.
  auto *timer = new QTimer(this);
  connect(timer, &QTimer::timeout, this, &MainWindow::tick);
  timer->start(16);

  return newTab(nullptr) != nullptr;
}

GhosttySurface *MainWindow::newTab(ghostty_surface_t parent) {
  auto *surface = new GhosttySurface(m_app, this);
  QWidget *container = QWidget::createWindowContainer(surface, nullptr);
  container->setFocusPolicy(Qt::StrongFocus);

  // The tab page hosts the tab's split tree (initially one surface).
  auto *page = new QWidget(m_tabs);
  auto *pageLayout = new QVBoxLayout(page);
  pageLayout->setContentsMargins(0, 0, 0, 0);
  pageLayout->addWidget(container);

  const int index = m_tabs->addTab(page, QStringLiteral("Ghostty"));
  m_containers.insert(surface, container);
  m_tabs->setCurrentIndex(index);

  if (!surface->initialize(parent)) {
    m_containers.remove(surface);
    m_tabs->removeTab(index);
    delete page;  // also destroys the container and its surface
    return nullptr;
  }

  surface->requestActivate();
  return surface;
}

GhosttySurface *MainWindow::splitSurface(
    GhosttySurface *target, ghostty_action_split_direction_e dir) {
  QWidget *container = m_containers.value(target);
  if (!container) return nullptr;

  const bool horizontal = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT ||
                          dir == GHOSTTY_SPLIT_DIRECTION_LEFT;
  const bool newAfter = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT ||
                        dir == GHOSTTY_SPLIT_DIRECTION_DOWN;

  auto *surface = new GhosttySurface(m_app, this);
  QWidget *newContainer = QWidget::createWindowContainer(surface, nullptr);
  newContainer->setFocusPolicy(Qt::StrongFocus);

  auto *splitter =
      new QSplitter(horizontal ? Qt::Horizontal : Qt::Vertical);
  splitter->setChildrenCollapsible(false);

  // Insert `splitter` where `container` currently sits in the tree.
  QWidget *parent = container->parentWidget();
  if (auto *parentSplitter = qobject_cast<QSplitter *>(parent)) {
    parentSplitter->replaceWidget(parentSplitter->indexOf(container),
                                  splitter);
  } else if (parent && parent->layout()) {
    delete parent->layout()->replaceWidget(container, splitter);
  } else {
    delete splitter;
    delete newContainer;  // also destroys the new surface
    return nullptr;
  }

  // `container` is now parentless; place it and the new pane in order.
  if (newAfter) {
    splitter->addWidget(container);
    splitter->addWidget(newContainer);
  } else {
    splitter->addWidget(newContainer);
    splitter->addWidget(container);
  }
  splitter->setSizes({1 << 20, 1 << 20});  // start the panes roughly equal

  m_containers.insert(surface, newContainer);

  if (!surface->initialize(target->surface())) {
    m_containers.remove(surface);
    delete newContainer;  // leaves a one-pane splitter; near-impossible path
    return nullptr;
  }

  surface->requestActivate();
  return surface;
}

void MainWindow::removeSurface(GhosttySurface *surface) {
  const auto it = m_containers.find(surface);
  if (it == m_containers.end()) return;
  QWidget *container = it.value();
  m_containers.erase(it);

  QWidget *parent = container->parentWidget();

  if (auto *splitter = qobject_cast<QSplitter *>(parent)) {
    // One pane of a split: collapse the splitter into its sibling.
    QWidget *sibling = nullptr;
    for (int i = 0; i < splitter->count(); ++i)
      if (splitter->widget(i) != container) sibling = splitter->widget(i);

    QWidget *splitterParent = splitter->parentWidget();
    if (auto *grand = qobject_cast<QSplitter *>(splitterParent)) {
      grand->replaceWidget(grand->indexOf(splitter), sibling);
    } else if (splitterParent && splitterParent->layout()) {
      delete splitterParent->layout()->replaceWidget(splitter, sibling);
    }
    // Deleting the now-orphaned splitter also deletes `container`.
    splitter->deleteLater();
    return;
  }

  // Otherwise this surface is the whole tab.
  const int index = m_tabs->indexOf(parent);
  if (index >= 0) m_tabs->removeTab(index);
  if (parent) parent->deleteLater();  // page; deletes the container too
  if (m_tabs->count() == 0) close();
}

void MainWindow::closeTab(int index) {
  QWidget *page = m_tabs->widget(index);
  if (!page) return;

  // Drop every surface hosted anywhere inside this tab's split tree.
  const auto surfaces = m_containers.keys();
  for (GhosttySurface *s : surfaces) {
    QWidget *c = m_containers.value(s);
    if (c && page->isAncestorOf(c)) m_containers.remove(s);
  }
  m_tabs->removeTab(index);
  page->deleteLater();  // destroys all contained surfaces
  if (m_tabs->count() == 0) close();
}

void MainWindow::setSurfaceTitle(GhosttySurface *surface,
                                 const QString &title) {
  const int index = tabIndexForSurface(surface);
  if (index < 0) return;
  m_tabs->setTabText(index, title);
  if (index == m_tabs->currentIndex())
    setWindowTitle(title + QStringLiteral(" — Ghostty"));
}

void MainWindow::tick() {
  if (!m_app) return;
  ghostty_app_tick(m_app);

  // Close any pane whose child process has exited.
  const auto surfaces = m_containers.keys();
  for (GhosttySurface *s : surfaces) {
    if (s->surface() && ghostty_surface_process_exited(s->surface()))
      removeSurface(s);
  }
}

void MainWindow::onTabCloseRequested(int index) { closeTab(index); }

void MainWindow::onCurrentChanged(int index) {
  GhosttySurface *s = surfaceAt(index);
  if (!s) return;
  s->requestActivate();
  setWindowTitle(m_tabs->tabText(index) + QStringLiteral(" — Ghostty"));
}

GhosttySurface *MainWindow::surfaceAt(int index) const {
  QWidget *page = m_tabs->widget(index);
  if (!page) return nullptr;
  for (auto it = m_containers.cbegin(); it != m_containers.cend(); ++it)
    if (page->isAncestorOf(it.value())) return it.key();
  return nullptr;
}

int MainWindow::tabIndexForSurface(GhosttySurface *surface) const {
  QWidget *container = m_containers.value(surface);
  if (!container) return -1;
  for (int i = 0; i < m_tabs->count(); ++i)
    if (m_tabs->widget(i)->isAncestorOf(container)) return i;
  return -1;
}

// --- libghostty runtime callbacks ------------------------------------

void MainWindow::onWakeup(void *ud) {
  // app userdata; hop to the GUI thread to tick.
  auto *self = static_cast<MainWindow *>(ud);
  QMetaObject::invokeMethod(self, "tick", Qt::QueuedConnection);
}

bool MainWindow::onAction(ghostty_app_t app, ghostty_target_s target,
                          ghostty_action_s action) {
  auto *self = static_cast<MainWindow *>(ghostty_app_userdata(app));
  if (!self) return false;

  // The surface this action targets, if any.
  GhosttySurface *src = nullptr;
  if (target.tag == GHOSTTY_TARGET_SURFACE && target.target.surface)
    src = static_cast<GhosttySurface *>(
        ghostty_surface_userdata(target.target.surface));

  // Actions may be dispatched from non-GUI threads, so window-touching
  // work is marshalled onto the GUI thread.
  switch (action.tag) {
    case GHOSTTY_ACTION_NEW_TAB:
    case GHOSTTY_ACTION_NEW_WINDOW: {
      // This single-window app maps new windows to new tabs.
      ghostty_surface_t parent = src ? src->surface() : nullptr;
      QMetaObject::invokeMethod(
          self, [self, parent]() { self->newTab(parent); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_NEW_SPLIT: {
      if (!src) return false;
      const ghostty_action_split_direction_e dir = action.action.new_split;
      QMetaObject::invokeMethod(
          self, [self, src, dir]() { self->splitSurface(src, dir); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_TAB:
      if (src)
        QMetaObject::invokeMethod(
            self, [self, src]() { self->removeSurface(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_SET_TITLE: {
      const char *title = action.action.set_title.title;
      if (!title || !src) return true;
      const QString t = QString::fromUtf8(title);
      QMetaObject::invokeMethod(
          self, [self, src, t]() { self->setSurfaceTitle(src, t); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      QMetaObject::invokeMethod(
          self, [self]() { self->close(); }, Qt::QueuedConnection);
      return true;

    default:
      // Fullscreen, tab navigation, etc. are not handled yet.
      return false;
  }
}

bool MainWindow::onReadClipboard(void *ud, ghostty_clipboard_e loc,
                                 void *state) {
  // surface userdata. Called synchronously when libghostty needs
  // clipboard contents (paste).
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface || !surface->surface()) return false;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QByteArray text = QGuiApplication::clipboard()->text(mode).toUtf8();
  ghostty_surface_complete_clipboard_request(surface->surface(),
                                             text.constData(), state, true);
  return true;
}

void MainWindow::onConfirmReadClipboard(void *ud, const char *str, void *state,
                                        ghostty_clipboard_request_e) {
  // The scaffold trusts pastes rather than showing an unsafe-paste
  // confirmation dialog. TODO: a real confirmation prompt.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (surface && surface->surface())
    ghostty_surface_complete_clipboard_request(surface->surface(), str, state,
                                               true);
}

void MainWindow::onWriteClipboard(void *ud, ghostty_clipboard_e loc,
                                  const ghostty_clipboard_content_s *content,
                                  size_t n, bool) {
  if (n == 0 || !content[0].data) return;
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface) return;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QString text = QString::fromUtf8(content[0].data);
  QMetaObject::invokeMethod(
      surface->owner(),
      [text, mode]() { QGuiApplication::clipboard()->setText(text, mode); },
      Qt::QueuedConnection);
}

void MainWindow::onCloseSurface(void *ud, bool) {
  // surface userdata.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface) return;
  MainWindow *self = surface->owner();
  QMetaObject::invokeMethod(
      self, [self, surface]() { self->removeSurface(surface); },
      Qt::QueuedConnection);
}
