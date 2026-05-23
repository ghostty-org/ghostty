#include "Util.h"

#include <QChar>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QStringList>
#include <QStringLiteral>
#include <QVariantMap>

// We index libghostty's GHOSTTY_KEY_DIGIT_0..9 and GHOSTTY_KEY_A..Z
// enum ranges by arithmetic offset. If libghostty ever inserts an
// entry into either range the math goes wrong silently — pin the
// contiguity at compile time.
static_assert(GHOSTTY_KEY_DIGIT_9 - GHOSTTY_KEY_DIGIT_0 == 9,
              "ghostty_input_key_e DIGIT_0..9 must be contiguous");
static_assert(GHOSTTY_KEY_Z - GHOSTTY_KEY_A == 25,
              "ghostty_input_key_e A..Z must be contiguous");

QString triggerKeyName(const ghostty_input_trigger_s &t) {
  switch (t.tag) {
    case GHOSTTY_TRIGGER_UNICODE:
      if (t.key.unicode) return QString(QChar(t.key.unicode)).toUpper();
      return {};
    case GHOSTTY_TRIGGER_PHYSICAL: {
      const ghostty_input_key_e k = t.key.physical;
      if (k >= GHOSTTY_KEY_DIGIT_0 && k <= GHOSTTY_KEY_DIGIT_9)
        return QChar('0' + (k - GHOSTTY_KEY_DIGIT_0));
      if (k >= GHOSTTY_KEY_A && k <= GHOSTTY_KEY_Z)
        return QChar('A' + (k - GHOSTTY_KEY_A));
      if (k == GHOSTTY_KEY_ENTER) return QStringLiteral("Return");
      if (k == GHOSTTY_KEY_SPACE) return QStringLiteral("Space");
      if (k == GHOSTTY_KEY_TAB) return QStringLiteral("Tab");
      return {};
    }
    default:
      return {};
  }
}

void postNotification(const QString &title, const QString &body) {
  QDBusMessage msg = QDBusMessage::createMethodCall(
      QStringLiteral("org.freedesktop.Notifications"),
      QStringLiteral("/org/freedesktop/Notifications"),
      QStringLiteral("org.freedesktop.Notifications"),
      QStringLiteral("Notify"));
  msg.setArguments({
      QStringLiteral("Ghastty"),             // app_name
      uint(0),                               // replaces_id
      QStringLiteral("ghastty"),             // app_icon
      title,                                 // summary
      body,                                  // body
      QStringList(),                         // actions
      QVariantMap(),                         // hints
      -1,                                    // expire_timeout (default)
  });
  QDBusConnection::sessionBus().send(msg);  // fire-and-forget
}

QString formatTrigger(const ghostty_input_trigger_s &t) {
  QString s;
  if (t.mods & GHOSTTY_MODS_CTRL) s += QStringLiteral("Ctrl+");
  if (t.mods & GHOSTTY_MODS_ALT) s += QStringLiteral("Alt+");
  if (t.mods & GHOSTTY_MODS_SHIFT) s += QStringLiteral("Shift+");
  if (t.mods & GHOSTTY_MODS_SUPER) s += QStringLiteral("Super+");

  const QString name = triggerKeyName(t);
  if (!name.isEmpty()) {
    s += name;
  } else if (t.tag == GHOSTTY_TRIGGER_PHYSICAL) {
    s += QStringLiteral("•");  // an unmapped physical key
  } else {
    s += QStringLiteral("…");  // CATCH_ALL etc.
  }
  return s;
}
