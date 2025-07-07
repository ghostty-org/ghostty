//! Fonts that can be embedded with Ghostty. Note they are only actually
//! embedded in the binary if they are referenced by the code, so fonts
//! used for tests will not result in the final binary being larger.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

/// Default fonts that we prefer for Ghostty.
pub const variable = @embedFile("jetbrains_mono_variable");
pub const variable_italic = @embedFile("jetbrains_mono_variable_italic");

/// Symbols-only nerd font.
pub const symbols_nerd_font = @embedFile("nerd_fonts_symbols_only");

/// Static jetbrains mono faces, currently unused.
pub const regular = @embedFile("jetbrains_mono_regular");
pub const bold = @embedFile("jetbrains_mono_bold");
pub const italic = @embedFile("jetbrains_mono_italic");
pub const bold_italic = @embedFile("jetbrains_mono_bold_italic");

/// Emoji fonts
pub const emoji = @embedFile("res/NotoColorEmoji.ttf");
pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");

// Fonts below are ONLY used for testing.

/// Fonts with general properties
pub const arabic = @embedFile("res/KawkabMono-Regular.ttf");

/// A font for testing which is patched with nerd font symbols.
pub const test_nerd_font = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");

/// Specific font families below:
pub const code_new_roman = @embedFile("res/CodeNewRoman-Regular.otf");
pub const inconsolata = @embedFile("res/Inconsolata-Regular.ttf");
pub const geist_mono = @embedFile("res/GeistMono-Regular.ttf");
pub const jetbrains_mono = @embedFile("res/JetBrainsMonoNoNF-Regular.ttf");
pub const julia_mono = @embedFile("res/JuliaMono-Regular.ttf");

/// Cozette is a unique font because it embeds some emoji characters
/// but has a text presentation.
pub const cozette = @embedFile("res/CozetteVector.ttf");

/// Monaspace has weird ligature behaviors we want to test in our shapers
/// so we embed it here.
pub const monaspace_neon = @embedFile("res/MonaspaceNeon-Regular.otf");

/// Terminus TTF is a scalable font with bitmap glyphs at various sizes.
pub const terminus_ttf = @embedFile("res/TerminusTTF-Regular.ttf");
