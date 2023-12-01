//! Fonts that can be embedded with Ghostty. Note they are only actually
//! embedded in the binary if they are referenced by the code, so fonts
//! used for tests will not result in the final binary being larger.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

/// Fonts with general properties
pub const fontRegular = @embedFile("res/Inconsolata-Regular.ttf");
pub const fontBold = @embedFile("res/Inconsolata-Bold.ttf");
pub const fontEmoji = @embedFile("res/NotoColorEmoji.ttf");
pub const fontEmojiText = @embedFile("res/NotoEmoji-Regular.ttf");
pub const fontVariable = @embedFile("res/Lilex-VF.ttf");

/// Cozette is a unique font because it embeds some emoji characters
/// but has a text presentation.
pub const fontCozette = @embedFile("res/CozetteVector.ttf");
