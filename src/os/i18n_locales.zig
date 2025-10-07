// NOTE: This is in a separate file because our build depends on it and
// we want to minimize the transitive dependencies of the build binary
// itself.

/// Supported locales for the application. This must be kept up to date
/// with the translations available in the `po/` directory; this is used
/// by our build process as well runtime libghostty APIs.
///
/// The order also matters. For incomplete locale information (i.e. only
/// a language code available), the first match is used. For example, if
/// we know the user requested `zh` but has no script code, then we'd pick
/// the first locale that matches `zh`.
///
/// For ordering, we prefer:
///
///   1. The most common locales first, since there are places in the code
///      where we do linear searches for a locale and we want to minimize
///      the number of iterations for the common case.
///
///   2. Alphabetical for otherwise equally common locales.
///
///   3. Most preferred locale for a language without a country code.
///
/// Note for "most common" locales, this is subjective and based on
/// the perceived userbase of Ghostty, which may not be representative
/// of general populations or global language distribution. Also note
/// that ordering may be weird when we first merge a new locale since
/// we don't have a good way to determine this. We can always reorder
/// with some data.
pub const locales = [_][:0]const u8{
    "zh_CN.UTF-8",
    "de_DE.UTF-8",
    "fr_FR.UTF-8",
    "ja_JP.UTF-8",
    "nl_NL.UTF-8",
    "nb_NO.UTF-8",
    "ru_RU.UTF-8",
    "uk_UA.UTF-8",
    "pl_PL.UTF-8",
    "ko_KR.UTF-8",
    "mk_MK.UTF-8",
    "tr_TR.UTF-8",
    "id_ID.UTF-8",
    "es_BO.UTF-8",
    "es_AR.UTF-8",
    "pt_BR.UTF-8",
    "ca_ES.UTF-8",
    "it_IT.UTF-8",
    "bg_BG.UTF-8",
    "ga_IE.UTF-8",
    "hu_HU.UTF-8",
    "he_IL.UTF-8",
    "zh_TW.UTF-8",
    "hr_HR.UTF-8",
};
