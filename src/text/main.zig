//! Text processing module for the terminal
//!
//! Provides utilities for:
//! - Bidirectional text support (Arabic, Hebrew, etc.)
//! - Text analysis and properties
//! - Complex script handling

pub const bidi = @import("BiDi.zig");

// Re-export commonly used types
pub const BiDiScript = bidi.Script;
pub const BiDiLevel = bidi.Level;
pub const BiDiAnalysisResult = bidi.AnalysisResult;

// Re-export functions
pub const detectScript = bidi.detectScript;
pub const isComplexScript = bidi.isComplexScript;
pub const isRtlScript = bidi.isRtlScript;
pub const analyzeBidi = bidi.analyzeBidi;
pub const getBaseDirection = bidi.getBaseDirection;

test {
    _ = bidi;
}
