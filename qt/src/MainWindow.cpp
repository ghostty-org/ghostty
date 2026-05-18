#include "MainWindow.h"

#include <cstdio>

#include <QByteArray>
#include <QClipboard>
#include <QGuiApplication>
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
  QWidget *container = QWidget::createWindowContainer(surface, m_tabs);
  container->setFocusPolicy(Qt::StrongFocus);

  const int index = m_tabs->addTab(container, QStringLiteral("Ghostty"));
  m_containers.insert(surface, container);
  m_tabs->setCurrentIndex(index);

  if (!surface->initialize(parent)) {
    m_containers.remove(surface);
    m_tabs->removeTab(index);
    delete container;  // also destroys the GhosttySurface window
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
  const int index = m_tabs->indexOf(container);
  if (index >= 0) m_tabs->removeTab(index);
  container->deleteLater();  // also destroys the GhosttySurface window

  if (m_tabs->count() == 0) close();
}

void MainWindow::setSurfaceTitle(GhosttySurface *surface,
                                 const QString &title) {
  const int index = indexOfSurface(surface);
  if (index < 0) return;
  m_tabs->setTabText(index, title);
  if (index == m_tabs->currentIndex())
    setWindowTitle(title + QStringLiteral(" — Ghostty"));
}

void MainWindow::tick() {
  if (!m_app) return;
  ghostty_app_tick(m_app);

  // Close any tab whose child process has exited.
  const auto surfaces = m_containers.keys();
  for (GhosttySurface *s : surfaces) {
    if (s->surface() && ghostty_surface_process_exited(s->surface()))
      removeSurface(s);
  }
}

void MainWindow::onTabCloseRequested(int index) {
  if (GhosttySurface *s = surfaceAt(index)) removeSurface(s);
}

void MainWindow::onCurrentChanged(int index) {
  GhosttySurface *s = surfaceAt(index);
  if (!s) return;
  s->requestActivate();
  setWindowTitle(m_tabs->tabText(index) + QStringLiteral(" — Ghostty"));
}

GhosttySurface *MainWindow::surfaceAt(int index) const {
  QWidget *w = m_tabs->widget(index);
  if (!w) return nullptr;
  for (auto it = m_containers.cbegin(); it != m_containers.cend(); ++it)
    if (it.value() == w) return it.key();
  return nullptr;
}

int MainWindow::indexOfSurface(GhosttySurface *surface) const {
  QWidget *container = m_containers.value(surface);
  return container ? m_tabs->indexOf(container) : -1;
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
      // Splits, fullscreen, tab navigation, etc. are not handled yet.
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
