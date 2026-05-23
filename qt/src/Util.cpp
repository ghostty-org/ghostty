#include "Util.h"

#include <QByteArray>
#include <QChar>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDir>
#include <QFile>
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

uint64_t parseDurationNs(const QString &s, uint64_t fallback) {
  if (s.isEmpty()) return fallback;
  // Order matters: longer units first so `ms` is matched before `s`,
  // `us` before `s`, etc. Mirrors Config.zig's units array.
  static constexpr struct { const char *name; uint64_t factor; } kUnits[] = {
      {"ns", 1ULL},
      {"us", 1000ULL},
      {"µs", 1000ULL},
      {"ms", 1000000ULL},
      {"s",  1000000000ULL},
      {"m",  60ULL * 1000000000ULL},
      {"h",  3600ULL * 1000000000ULL},
      {"d",  86400ULL * 1000000000ULL},
      {"w",  7ULL * 86400ULL * 1000000000ULL},
      {"y",  365ULL * 86400ULL * 1000000000ULL},
  };
  uint64_t total = 0;
  int i = 0;
  const int n = s.size();
  bool anyMatched = false;
  while (i < n) {
    while (i < n && s.at(i).isSpace()) ++i;
    if (i >= n) break;
    int start = i;
    while (i < n && s.at(i).isDigit()) ++i;
    if (i == start) return fallback;  // expected a number
    bool ok = false;
    const uint64_t value = s.mid(start, i - start).toULongLong(&ok);
    if (!ok) return fallback;
    while (i < n && s.at(i).isSpace()) ++i;
    // Match the longest unit prefix at i. unitLen is counted in
    // QChar (UTF-16 code unit) length, NOT byte length, because `i`
    // and `s.size()` are QChar-counted. `µs` is 3 UTF-8 bytes but
    // 2 QChars (µ + s); using qstrlen here over-advanced past the
    // input.
    const QString rest = s.mid(i);
    uint64_t factor = 0;
    int unitLen = 0;
    for (const auto &u : kUnits) {
      const QString unit = QString::fromUtf8(u.name);
      const int ulen = unit.size();
      if (rest.startsWith(unit) && ulen > unitLen) {
        factor = u.factor;
        unitLen = ulen;
      }
    }
    if (unitLen == 0) return fallback;
    total += value * factor;
    i += unitLen;
    anyMatched = true;
  }
  return anyMatched ? total : fallback;
}

QString configValue(const QString &key) {
  QString dir = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (dir.isEmpty()) dir = QDir::homePath() + QStringLiteral("/.config");

  QFile f(dir + QStringLiteral("/ghostty/config"));
  if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};

  const QByteArray wanted = key.toUtf8();
  QString value;
  while (!f.atEnd()) {
    const QByteArray line = f.readLine().trimmed();
    const int eq = line.indexOf('=');
    if (eq < 0 || line.left(eq).trimmed() != wanted) continue;
    value = QString::fromUtf8(line.mid(eq + 1).trimmed());
  }
  return value;
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
