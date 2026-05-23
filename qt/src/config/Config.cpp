#include "Config.h"

#include <climits>

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
// when parsing fails, when the input is empty, or when the running
// total would overflow uint64 (Config.zig rejects this; we mirror).
static uint64_t parseDurationNs(const QString &s, uint64_t fallback) {
  if (s.isEmpty()) return fallback;
  // kUnits mirrors Config.zig's units array; the longest-prefix match
  // at the matching site below makes table order semantically
  // irrelevant (kept aligned with Zig for diffability).
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
    // Reject overflow on multiply or running-sum: a typo like
    // `1000000000y` would otherwise wrap into a small bogus value
    // that callers treat as a real (tiny) duration.
    if (factor && value > ULLONG_MAX / factor) return fallback;
    const uint64_t segment = value * factor;
    if (segment > ULLONG_MAX - total) return fallback;
    total += segment;
    i += unitLen;
    anyMatched = true;
  }
  return anyMatched ? total : fallback;
}

uint64_t durationNs(const char *key, uint64_t fallbackNs) {
  return parseDurationNs(diskValue(key), fallbackNs);
}

unsigned int bitfield(const char *key, unsigned int fallbackBits) {
  unsigned int bits = 0;
  ghostty_config_t cfg = handle();
  if (cfg && ghostty_config_get(cfg, &bits, key, qstrlen(key))) return bits;
  return fallbackBits;
}

QString expandedPath(const char *key) {
  QString p = diskValue(key);
  if (p.startsWith(QLatin1String("~/"))) p = QDir::homePath() + p.mid(1);
  return p;
}

bool hasCustomShader() {
  // libghostty does not expose this through ghostty_config_get
  // (`custom-shader` is a repeatable path), so scan the on-disk
  // config text. diskValue does the exact-key match (so
  // `custom-shader-animation = …` is not mistaken for our key) and
  // last-write-wins (so `custom-shader =` clears any earlier
  // assignment, matching libghostty's repeating-key semantics).
  return !diskValue("custom-shader").isEmpty();
}

}  // namespace config
