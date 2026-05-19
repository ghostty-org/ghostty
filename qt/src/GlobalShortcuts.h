#pragma once

#include <QHash>
#include <QObject>
#include <QString>
#include <QVariantMap>

class QDBusMessage;

// Registers global shortcuts through the org.freedesktop.portal
// GlobalShortcuts XDG portal, so actions like the quick terminal can be
// triggered while Ghostty is unfocused (a normal Wayland client cannot
// see keys when unfocused).
//
// The portal model: the app declares named shortcuts; the desktop
// (KDE System Settings -> Shortcuts) owns the actual key assignment.
// activated() fires with the shortcut id when one is triggered.
class GlobalShortcuts : public QObject {
  Q_OBJECT

public:
  explicit GlobalShortcuts(QObject *parent = nullptr);

signals:
  void activated(const QString &id);

private slots:
  // Every portal Request's Response lands here; m_requests maps the
  // request path back to the method that started it.
  void onResponse(const QDBusMessage &message);
  void onActivated(const QDBusMessage &message);

private:
  // Invoke a GlobalShortcuts method on org.freedesktop.portal.Desktop.
  // `options` gets a fresh handle_token and is appended as the trailing
  // argument every portal method expects.
  void portalCall(const QString &method, QVariantList args,
                  QVariantMap options);
  void handleCreateSession(uint code, const QVariantMap &results);
  QString requestPath(const QString &token) const;
  QString nextToken();

  QString m_sessionHandle;          // the portal session object path
  QHash<QString, QString> m_requests;  // request path -> method name
  int m_tokenCounter = 0;
};
