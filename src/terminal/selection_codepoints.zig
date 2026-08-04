// This file contains various default word boundaries used for
// selection logic. We put it in a separate file so that different
// subsystems can import it without introducing a number of
// dependencies.

/// Default boundary characters for word selection.
///
/// Latin: ` \t'"│`|:;,()[]{}<>$`, plus punctuation from right-to-left
/// scripts and the dashes and angle quotes those scripts commonly use.
pub const default_word_boundaries = [_]u21{
    0, // null
    ' ', // space
    '\t', // tab
    '\'', // single quote
    '"', // double quote
    '│', // U+2502 box drawing
    '`', // backtick
    '|', // pipe
    ':', // colon
    ';', // semicolon
    ',', // comma
    '(', // left paren
    ')', // right paren
    '[', // left bracket
    ']', // right bracket
    '{', // left brace
    '}', // right brace
    '<', // less than
    '>', // greater than
    '$', // dollar

    // Punctuation from right-to-left scripts, which separates words
    // exactly as its Latin counterparts do. Without these, double
    // clicking anywhere in an Arabic or Persian sentence selects the
    // whole sentence, because nothing in it is recognized as a break.
    //
    // The letters and digits of those scripts deliberately do NOT
    // appear here: a word character is anything that is not a boundary,
    // so they are already handled. That includes the Eastern
    // Arabic-Indic digits Persian uses, and the zero width non-joiner
    // that holds Persian compounds together, which is stored as part of
    // its neighbour's grapheme and so never reaches this list at all.
    '\u{060C}', // Arabic comma
    '\u{061B}', // Arabic semicolon
    '\u{061F}', // Arabic question mark
    '\u{06D4}', // Arabic full stop
    '\u{060D}', // Arabic date separator
    '\u{066C}', // Arabic thousands separator
    '\u{05BE}', // Hebrew maqaf, which joins words but reads as a hyphen
    '\u{05C0}', // Hebrew paseq
    '\u{05C3}', // Hebrew sof pasuq
    '\u{05F3}', // Hebrew geresh
    '\u{05F4}', // Hebrew gershayim
    '\u{2010}', // hyphen
    '\u{2013}', // en dash
    '\u{2014}', // em dash
    '\u{00AB}', // left-pointing double angle quotation
    '\u{00BB}', // right-pointing double angle quotation
};

/// Default whitespace characters trimmed from line selections.
pub const default_line_whitespace = [_]u21{ 0, ' ', '\t' };
