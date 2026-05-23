#include "XkbState.h"

#include <xkbcommon/xkbcommon.h>

#include "../XkbTracker.h"

XkbState &XkbState::instance() {
  static XkbState self;
  return self;
}

XkbState::~XkbState() {
  // Run on process exit when the static is destroyed. The OS would
  // reclaim regardless, but explicit teardown silences leak checkers
  // and documents the ownership chain.
  if (m_query) xkb_state_unref(m_query);
  if (m_unshifted) xkb_state_unref(m_unshifted);
  if (m_keymap) xkb_keymap_unref(m_keymap);
  if (m_fallbackKeymap) xkb_keymap_unref(m_fallbackKeymap);
}

uint32_t XkbState::unshiftedCodepoint(uint32_t keycode) const {
  syncFromTracker();
  if (!m_unshifted) return 0;
  const xkb_keysym_t sym =
      xkb_state_key_get_one_sym(m_unshifted, keycode);
  if (sym == XKB_KEY_NoSymbol) return 0;
  return xkb_keysym_to_utf32(sym);
}

ghostty_input_mods_e XkbState::sideBitsForKeycode(uint32_t keycode) const {
  syncFromTracker();
  if (!m_unshifted) return GHOSTTY_MODS_NONE;
  const xkb_keysym_t sym =
      xkb_state_key_get_one_sym(m_unshifted, keycode);
  int r = GHOSTTY_MODS_NONE;
  switch (sym) {
    case XKB_KEY_Shift_R: r |= GHOSTTY_MODS_SHIFT_RIGHT; break;
    case XKB_KEY_Control_R: r |= GHOSTTY_MODS_CTRL_RIGHT; break;
    // Both Alt_R and ISO_Level3_Shift (AltGr) are right-Alt physically.
    case XKB_KEY_Alt_R:
    case XKB_KEY_ISO_Level3_Shift: r |= GHOSTTY_MODS_ALT_RIGHT; break;
    case XKB_KEY_Super_R:
    case XKB_KEY_Hyper_R:
    case XKB_KEY_Meta_R: r |= GHOSTTY_MODS_SUPER_RIGHT; break;
    default: break;
  }
  return static_cast<ghostty_input_mods_e>(r);
}

ghostty_input_mods_e XkbState::lockMods() const {
  int r = GHOSTTY_MODS_NONE;
  if (XkbTracker *t = XkbTracker::instance()) {
    if (t->capsLockOn()) r |= GHOSTTY_MODS_CAPS;
    if (t->numLockOn()) r |= GHOSTTY_MODS_NUM;
  }
  return static_cast<ghostty_input_mods_e>(r);
}

ghostty_input_mods_e XkbState::consumedMods(uint32_t keycode,
                                            ghostty_input_mods_e mods) const {
  syncFromTracker();
  if (!m_query) return GHOSTTY_MODS_NONE;
  xkb_mod_mask_t depressed = 0;
  if ((mods & GHOSTTY_MODS_SHIFT) && m_idxShift != XKB_MOD_INVALID)
    depressed |= (1u << m_idxShift);
  if ((mods & GHOSTTY_MODS_CTRL) && m_idxCtrl != XKB_MOD_INVALID)
    depressed |= (1u << m_idxCtrl);
  if ((mods & GHOSTTY_MODS_ALT) && m_idxAlt != XKB_MOD_INVALID)
    depressed |= (1u << m_idxAlt);
  if ((mods & GHOSTTY_MODS_SUPER) && m_idxSuper != XKB_MOD_INVALID)
    depressed |= (1u << m_idxSuper);
  // Use the live group from the tracker so a layout switch (e.g.
  // us↔ru) takes effect immediately.
  XkbTracker *t = XkbTracker::instance();
  const uint32_t group = t ? t->activeGroup() : 0;
  xkb_state_update_mask(m_query, depressed, 0, 0, 0, 0, group);
  const xkb_mod_mask_t consumed = xkb_state_key_get_consumed_mods2(
      m_query, keycode, XKB_CONSUMED_MODE_XKB);
  // Reset so the next query starts from no-mods.
  xkb_state_update_mask(m_query, 0, 0, 0, 0, 0, group);
  int r = GHOSTTY_MODS_NONE;
  if (m_idxShift != XKB_MOD_INVALID && (consumed & (1u << m_idxShift)))
    r |= GHOSTTY_MODS_SHIFT;
  if (m_idxCtrl != XKB_MOD_INVALID && (consumed & (1u << m_idxCtrl)))
    r |= GHOSTTY_MODS_CTRL;
  if (m_idxAlt != XKB_MOD_INVALID && (consumed & (1u << m_idxAlt)))
    r |= GHOSTTY_MODS_ALT;
  if (m_idxSuper != XKB_MOD_INVALID && (consumed & (1u << m_idxSuper)))
    r |= GHOSTTY_MODS_SUPER;
  return static_cast<ghostty_input_mods_e>(r);
}

void XkbState::syncFromTracker() const {
  XkbTracker *t = XkbTracker::instance();
  xkb_keymap *liveKm = t ? t->keymap() : nullptr;
  xkb_keymap *km = liveKm ? liveKm : m_fallbackKeymap;

  if (!km && t && t->ctx()) {
    // Compositor hasn't sent a keymap yet (early startup). Build a
    // throwaway from XKB defaults so the first key event isn't
    // dropped; it will be replaced on the next syncFromTracker
    // call once the tracker has the live keymap.
    m_fallbackKeymap = xkb_keymap_new_from_names(
        t->ctx(), nullptr, XKB_KEYMAP_COMPILE_NO_FLAGS);
    km = m_fallbackKeymap;
  }
  if (!km || km == m_keymap) {
    // Already synced (or no keymap available at all).
    // Update the live group on m_unshifted so the level-0 lookup
    // honors the active layout, even when the keymap pointer
    // hasn't changed.
    if (m_unshifted && t) {
      xkb_state_update_mask(m_unshifted, 0, 0, 0, 0, 0, t->activeGroup());
    }
    return;
  }

  // The live keymap was rebuilt by the tracker (or we're picking
  // up the first one). Drop our derived states and rebuild. Take
  // an extra ref on the keymap while it's our cached identity so
  // the xkb allocator can't free it and reuse the same address
  // for a different keymap (the ABA hazard the previous comment
  // hand-waved away).
  if (m_unshifted) xkb_state_unref(m_unshifted);
  if (m_query) xkb_state_unref(m_query);
  if (m_keymap) xkb_keymap_unref(m_keymap);
  m_keymap = xkb_keymap_ref(km);
  m_unshifted = xkb_state_new(km);
  m_query = xkb_state_new(km);
  m_idxShift = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_SHIFT);
  m_idxCtrl = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_CTRL);
  m_idxAlt = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_ALT);
  m_idxSuper = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_LOGO);
  if (t)
    xkb_state_update_mask(m_unshifted, 0, 0, 0, 0, 0, t->activeGroup());
}
