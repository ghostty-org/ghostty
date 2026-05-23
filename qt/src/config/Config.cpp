#include "Config.h"

#include <QByteArray>
#include <QChar>
#include <QDir>
#include <QFile>
#include <QStringLiteral>

#include "../app/GhosttyApp.h"

namespace config {

ghostty_config_t handle() {
  return GhosttyApp::instance().config();
}

QString string(const char *key) {
  ghostty_config_t cfg = handle();
  const char *value = nullptr;
  if (!cfg || !ghostty_config_get(cfg, &value, key, qstrlen(key)) || !value)
    return {};
  return QString::fromUtf8(value);
}

bool boolean(const char *key, bool fallback) {
  bool value = fallback;  // ghostty_config_get leaves it untouched if absent
  if (ghostty_config_t cfg = handle())
    ghostty_config_get(cfg, &value, key, qstrlen(key));
  return value;
}

QString diskValue(const char *key) {
  QString dir = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (dir.isEmpty()) dir = QDir::homePath() + QStringLiteral("/.config");

  QFile f(dir + QStringLiteral("/ghostty/config"));
  if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};

  const QByteArray wanted(key);
  QString value;
  while (!f.atEnd()) {
    const QByteArray line = f.readLine().trimmed();
    const int eq = line.indexOf('=');
    if (eq < 0 || line.left(eq).trimmed() != wanted) continue;
    value = QString::fromUtf8(line.mid(eq + 1).trimmed());
  }
  return value;
}

// Parse a libghostty duration string into nanoseconds. The format is
// concatenated `<n><unit>` segments per Config.zig's Duration.parseCLI:
//   y w d h m s ms µs us ns
// Each segment is added to the total. Returns the supplied fallback
// when parsing fails or the input is empty.
static uint64_t parseDurationNs(const QString &s, uint64_t fallback) {
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

uint64_t durationNs(const char *key, uint64_t fallbackNs) {
  return parseDurationNs(diskValue(key), fallbackNs);
}

bool hasCustomShader() {
  // libghostty does not expose this through ghostty_config_get
  // (`custom-shader` is a repeatable path), so scan the primary
  // config file directly.
  QString dir = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (dir.isEmpty()) dir = QDir::homePath() + QStringLiteral("/.config");

  QFile f(dir + QStringLiteral("/ghostty/config"));
  if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return false;

  while (!f.atEnd()) {
    const QByteArray line = f.readLine().trimmed();
    if (!line.startsWith("custom-shader")) continue;
    // Require a non-empty value: `custom-shader =` alone clears it.
    const int eq = line.indexOf('=');
    if (eq >= 0 && !line.mid(eq + 1).trimmed().isEmpty()) return true;
  }
  return false;
}

}  // namespace config
