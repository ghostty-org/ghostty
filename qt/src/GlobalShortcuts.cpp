#include "GlobalShortcuts.h"

#include <cstdio>

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QVariant>
#include <QVariantList>

namespace {
constexpr const char *kService = "org.freedesktop.portal.Desktop";
constexpr const char *kPath = "/org/freedesktop/portal/desktop";
constexpr const char *kInterface = "org.freedesktop.portal.GlobalShortcuts";
constexpr const char *kRequest = "org.freedesktop.portal.Request";
}  // namespace

// One declared shortcut, marshalled as the portal's `(sa{sv})`.
struct PortalShortcut {
  QString id;
  QVariantMap props;
};
Q_DECLARE_METATYPE(PortalShortcut)

QDBusArgument &operator<<(QDBusArgument &arg, const PortalShortcut &s) {
  arg.beginStructure();
  arg << s.id << s.props;
  arg.endStructure();
  return arg;
}
const QDBusArgument &operator>>(const QDBusArgument &arg, PortalShortcut &s) {
  arg.beginStructure();
  arg >> s.id >> s.props;
  arg.endStructure();
  return arg;
}

GlobalShortcuts::GlobalShortcuts(QObject *parent) : QObject(parent) {
  qDBusRegisterMetaType<PortalShortcut>();
  qDBusRegisterMetaType<QList<PortalShortcut>>();

  QDBusConnection bus = QDBusConnection::sessionBus();
  // One broad subscription, registered now (before the event loop), so
  // no portal Response can outrun its match rule. An empty path makes
  // it match every Request object.
  bus.connect(QString::fromLatin1(kService), QString(),
              QString::fromLatin1(kRequest), QStringLiteral("Response"), this,
              SLOT(onResponse(QDBusMessage)));
  bus.connect(QString::fromLatin1(kService), QString::fromLatin1(kPath),
              QString::fromLatin1(kInterface), QStringLiteral("Activated"),
              this, SLOT(onActivated(QDBusMessage)));

  // Create a portal session; shortcut binding follows in its response.
  QVariantMap options;
  options[QStringLiteral("session_handle_token")] = nextToken();
  portalCall(QStringLiteral("CreateSession"), {}, options);
}

QString GlobalShortcuts::nextToken() {
  return QStringLiteral("ghostty%1").arg(m_tokenCounter++);
}

QString GlobalShortcuts::requestPath(const QString &token) const {
  // Per the portal Request docs: the path is derived from the caller's
  // unique bus name with the leading ':' dropped and '.' -> '_'.
  QString unique = QDBusConnection::sessionBus().baseService();
  if (unique.startsWith(QLatin1Char(':'))) unique.remove(0, 1);
  unique.replace(QLatin1Char('.'), QLatin1Char('_'));
  return QStringLiteral("/org/freedesktop/portal/desktop/request/%1/%2")
      .arg(unique, token);
}

void GlobalShortcuts::portalCall(const QString &method, QVariantList args,
                                 QVariantMap options) {
  const QString token = nextToken();
  options[QStringLiteral("handle_token")] = token;
  args.append(QVariant(options));  // the trailing a{sv} every method takes
  const QString path = requestPath(token);
  m_requests.insert(path, method);

  QDBusMessage msg = QDBusMessage::createMethodCall(
      QString::fromLatin1(kService), QString::fromLatin1(kPath),
      QString::fromLatin1(kInterface), method);
  msg.setArguments(args);

  // The real result arrives via the Response signal; watch the call
  // itself so a failed invocation is not silently swallowed AND the
  // m_requests entry is dropped (otherwise an errored portal call
  // would leak a Request entry forever).
  auto *watcher = new QDBusPendingCallWatcher(
      QDBusConnection::sessionBus().asyncCall(msg), this);
  connect(watcher, &QDBusPendingCallWatcher::finished, this,
          [this, method, path](QDBusPendingCallWatcher *w) {
            QDBusPendingReply<QDBusObjectPath> reply = *w;
            if (reply.isError()) {
              std::fprintf(stderr, "[ghastty] portal %s failed: %s\n",
                           method.toUtf8().constData(),
                           reply.error().message().toUtf8().constData());
              m_requests.remove(path);
            }
            w->deleteLater();
          });
}

void GlobalShortcuts::onResponse(const QDBusMessage &message) {
  const QString method = m_requests.take(message.path());
  if (method.isEmpty()) return;  // not one of ours
  const QVariantList args = message.arguments();
  if (args.isEmpty()) return;
  const uint code = args.at(0).toUInt();
  const QVariantMap results =
      args.size() > 1 ? qdbus_cast<QVariantMap>(args.at(1)) : QVariantMap();
  if (code != 0)
    std::fprintf(stderr, "[ghastty] portal %s response code=%u\n",
                 method.toUtf8().constData(), code);
  if (method == QLatin1String("CreateSession"))
    handleCreateSession(code, results);
}

void GlobalShortcuts::handleCreateSession(uint code,
                                          const QVariantMap &results) {
  if (code != 0) return;
  m_sessionHandle = results.value(QStringLiteral("session_handle")).toString();
  if (m_sessionHandle.isEmpty()) return;

  // Declare the shortcuts; the desktop owns the actual key assignment
  // (KDE System Settings -> Shortcuts).
  // preferred_trigger uses MOD+keysym form (LOGO == Super); the desktop
  // may honor it as the default key or let the user rebind it.
  QList<PortalShortcut> shortcuts;
  shortcuts.append(
      {QStringLiteral("toggle-quick-terminal"),
       {{QStringLiteral("description"),
         QStringLiteral("Toggle the Ghastty quick terminal")},
        {QStringLiteral("preferred_trigger"), QStringLiteral("LOGO+grave")}}});
  shortcuts.append(
      {QStringLiteral("toggle-visibility"),
       {{QStringLiteral("description"),
         QStringLiteral("Toggle Ghastty window visibility")}}});

  portalCall(QStringLiteral("BindShortcuts"),
             {QVariant::fromValue(QDBusObjectPath(m_sessionHandle)),
              QVariant::fromValue(shortcuts), QString()},
             {});
}

void GlobalShortcuts::onActivated(const QDBusMessage &message) {
  // Activated(o session_handle, s shortcut_id, t timestamp, a{sv} options)
  const QVariantList args = message.arguments();
  if (args.size() < 2) return;
  emit activated(args.at(1).toString());
}
