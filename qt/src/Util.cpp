#include "Util.h"

#include <QChar>
#include <QStringLiteral>

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
