//! Fonts that can be embedded with Ghostty. Note they are only actually
//! embedded in the binary if they are referenced by the code, so fonts
//! used for tests will not result in the final binary being larger.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

/// Default fonts that we prefer for Ghostty.
pub const regular = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");
pub const bold = @embedFile("res/JetBrainsMonoNerdFont-Bold.ttf");
pub const italic = @embedFile("res/JetBrainsMonoNerdFont-Italic.ttf");
pub const bold_italic = @embedFile("res/JetBrainsMonoNerdFont-BoldItalic.ttf");
pub const emoji = @embedFile("res/NotoColorEmoji.ttf");
pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");

/// Fonts with general properties
pub const arabic = @embedFile("res/KawkabMono-Regular.ttf");
pub const variable = @embedFile("res/Lilex-VF.ttf");

/// Font with nerd fonts embedded.
pub const nerd_font = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");

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
