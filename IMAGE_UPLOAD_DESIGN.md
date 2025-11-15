# Image Upload on Drag & Drop - Design Document

## Overview

This document outlines a design for enhancing Ghostty's drag & drop functionality to automatically upload image files to a configurable API endpoint and paste the returned URL into the terminal instead of the local file path.

## Goals

1. **Minimal Invasiveness**: Changes should be localized and easy to maintain when syncing with upstream
2. **Configurability**: Support for multiple image hosting APIs (Imgur, ImgBB, custom endpoints)
3. **Security**: Maintain Ghostty's existing clipboard safety mechanisms
4. **User Experience**: Seamless operation with clear feedback and error handling
5. **PR-Ready**: Professional implementation suitable for upstream contribution

## Current Behavior Analysis

### Existing Code Locations

#### GTK Implementation
- **File**: `src/apprt/gtk/class/surface.zig`
- **Function**: `dtDrop` (lines 2340-2422)
- **Process**:
  1. Receives dropped file(s) from `gtk.DropTarget`
  2. Extracts file path(s)
  3. Escapes paths using `ShellEscapeWriter` (`src/os/shell.zig`)
  4. Calls `Clipboard.paste()` to insert text into terminal

#### macOS Implementation
- **File**: `macos/Sources/Ghostty/SurfaceView_AppKit.swift`
- **Function**: `performDragOperation` (lines 1947-1980)
- **Process**:
  1. Receives `NSDraggingInfo` with file URLs
  2. Escapes paths using `Ghostty.Shell.escape()`
  3. Calls `insertText()` to paste into terminal

### File Type Detection
- **File**: `src/file_type.zig`
- **Capability**: Already supports detecting image formats:
  - JPEG, PNG, GIF, BMP, WebP, QOI
  - Detection via magic bytes and file extensions
  - Functions: `FileType.detect()` and `FileType.guessFromExtension()`

### Security Mechanisms
- **File**: `src/apprt/gtk/class/surface.zig:3462-3486`
- **Function**: `Clipboard.paste()` → `completeClipboardRequest()`
- **Features**:
  - `UnsafePaste` and `UnauthorizedPaste` error handling
  - User confirmation dialog for potentially unsafe content
  - Config option: `clipboard-paste-protection`

## Proposed Architecture

### 1. Configuration Schema

Add new configuration options to `src/config/Config.zig`:

```zig
/// Enable automatic image upload when dropping image files.
/// If disabled, image files will be pasted as file paths (default behavior).
@"image-upload-enable": bool = false,

/// API endpoint for image uploads. Supports templated variables.
/// Examples:
///   - https://api.imgur.com/3/image
///   - https://api.imgbb.com/1/upload
///   - https://your-server.com/api/upload
@"image-upload-url": ?[:0]const u8 = null,

/// HTTP method for upload request (GET or POST).
@"image-upload-method": ImageUploadMethod = .post,

/// Request format for image upload.
/// - multipart: Use multipart/form-data (most common)
/// - json: Send image as base64 in JSON
/// - binary: Send raw image bytes
@"image-upload-format": ImageUploadFormat = .multipart,

/// Field name for the image in the upload request.
/// For multipart: the form field name
/// For JSON: the JSON key name
@"image-upload-field": [:0]const u8 = "image",

/// Additional HTTP headers for the upload request.
/// Format: "Header-Name: value"
/// Can be specified multiple times for multiple headers.
/// Example: image-upload-header = "Authorization: Bearer YOUR_TOKEN"
@"image-upload-header": RepeatableString = .{},

/// JSONPath or regex to extract the URL from the API response.
/// Examples:
///   - json:$.data.link (JSONPath for Imgur)
///   - json:$.data.url (JSONPath for ImgBB)
///   - regex:https?://[^\s"]+ (regex fallback)
@"image-upload-response-path": [:0]const u8 = "json:$.data.link",

/// Maximum image file size to upload (in MB). Files larger than this
/// will fall back to pasting the local path.
@"image-upload-max-size": u32 = 10,

/// Timeout for upload requests in seconds.
@"image-upload-timeout": u32 = 30,

/// Show a notification/indicator while uploading.
@"image-upload-show-progress": bool = true,

/// Fallback behavior if upload fails.
/// - path: Paste the local file path
/// - error: Show error message and paste nothing
/// - empty: Paste nothing silently
@"image-upload-fallback": ImageUploadFallback = .path,
```

**Enums**:
```zig
pub const ImageUploadMethod = enum {
    get,
    post,

    pub fn parseCLI(value: []const u8) !ImageUploadMethod {
        // Parse from config
    }
};

pub const ImageUploadFormat = enum {
    multipart,  // multipart/form-data
    json,       // application/json with base64
    binary,     // application/octet-stream

    pub fn parseCLI(value: []const u8) !ImageUploadFormat {
        // Parse from config
    }
};

pub const ImageUploadFallback = enum {
    path,
    error,
    empty,

    pub fn parseCLI(value: []const u8) !ImageUploadFallback {
        // Parse from config
    }
};
```

### 2. Upload Module

Create new file: `src/image_upload.zig`

```zig
const std = @import("std");
const file_type = @import("file_type.zig");
const Config = @import("config.zig").Config;

pub const UploadResult = union(enum) {
    success: [:0]const u8,  // Uploaded URL
    failure: [:0]const u8,  // Error message
    fallback,               // Use fallback behavior
};

pub const Uploader = struct {
    allocator: std.mem.Allocator,
    config: *const Config,

    /// Upload an image file to the configured endpoint
    pub fn upload(
        self: *Uploader,
        file_path: []const u8,
    ) !UploadResult {
        // 1. Validate config
        if (!self.config.@"image-upload-enable") return .fallback;
        if (self.config.@"image-upload-url" == null) return .fallback;

        // 2. Detect if file is an image
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size > self.config.@"image-upload-max-size" * 1024 * 1024) {
            return .fallback;
        }

        // Read first bytes for magic detection
        var header: [16]u8 = undefined;
        _ = try file.read(&header);
        const ft = file_type.FileType.detect(&header);

        if (ft == .unknown) {
            // Try extension-based detection
            const ext = std.fs.path.extension(file_path);
            const ft_ext = file_type.FileType.guessFromExtension(ext);
            if (ft_ext == .unknown) return .fallback;
        }

        // 3. Read file contents
        try file.seekTo(0);
        const contents = try file.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(contents);

        // 4. Build HTTP request
        const url = self.config.@"image-upload-url".?;
        const uri = try std.Uri.parse(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // 5. Send request based on format
        const response = switch (self.config.@"image-upload-format") {
            .multipart => try self.uploadMultipart(&client, uri, contents),
            .json => try self.uploadJson(&client, uri, contents),
            .binary => try self.uploadBinary(&client, uri, contents),
        };
        defer self.allocator.free(response);

        // 6. Parse response to extract URL
        const uploaded_url = try self.parseResponse(response);

        return .{ .success = uploaded_url };
    }

    fn uploadMultipart(/*...*/) ![]u8 { /* ... */ }
    fn uploadJson(/*...*/) ![]u8 { /* ... */ }
    fn uploadBinary(/*...*/) ![]u8 { /* ... */ }
    fn parseResponse(/*...*/) ![:0]const u8 { /* ... */ }
};
```

### 3. Integration Points

#### A. Modify Drop Handlers

**GTK**: `src/apprt/gtk/class/surface.zig:dtDrop`

```zig
fn dtDrop(
    _: *gtk.DropTarget,
    value: *gobject.Value,
    _: f64,
    _: f64,
    self: *Self,
) callconv(.c) c_int {
    const alloc = Application.default().allocator();

    if (ext.gValueHolds(value, gio.File.getGObjectType())) {
        const object = value.getObject() orelse return 0;
        const file = gobject.ext.cast(gio.File, object) orelse return 0;
        const path = file.getPath() orelse return 0;
        const path_slice = std.mem.span(path);
        defer glib.free(path);

        // NEW: Try image upload first
        const priv = self.private();
        if (priv.core_surface) |surface| {
            if (surface.config.@"image-upload-enable") {
                // SHOW PROGRESS OVERLAY (does NOT write to terminal!)
                priv.progress_bar_overlay.as(gtk.Widget).setVisible(true);
                priv.progress_bar_overlay.pulse();

                var uploader = image_upload.Uploader{
                    .allocator = alloc,
                    .config = &surface.config,
                };

                const result = uploader.upload(path_slice) catch .fallback;

                // HIDE PROGRESS OVERLAY
                priv.progress_bar_overlay.as(gtk.Widget).setVisible(false);

                switch (result) {
                    .success => |url| {
                        // NOW paste the uploaded URL to terminal
                        Clipboard.paste(self, url);
                        return 1;
                    },
                    .failure => |err| {
                        // Handle based on fallback config
                        switch (surface.config.@"image-upload-fallback") {
                            .path => {}, // Continue to normal path paste below
                            .error => {
                                // Show error notification
                                log.err("image upload failed: {s}", .{err});
                                return 0;
                            },
                            .empty => return 1,
                        }
                    },
                    .fallback => {}, // Continue to normal behavior
                }
            }
        }

        // EXISTING: Default behavior - paste file path
        var stream: std.Io.Writer.Allocating = .init(alloc);
        defer stream.deinit();
        // ... rest of existing code
    }

    // ... rest of function
}
```

**macOS**: Similar modifications in `macos/Sources/Ghostty/SurfaceView_AppKit.swift:performDragOperation`

#### B. Async Upload Support (Phase 3 Enhancement)

To avoid blocking the UI during upload, implement async upload with thread:

```zig
// In src/image_upload.zig
pub const AsyncUploader = struct {
    thread: std.Thread,
    result: ?UploadResult = null,
    done: std.atomic.Value(bool),

    pub fn start(/*...*/) !*AsyncUploader {
        const self = try allocator.create(AsyncUploader);
        self.done = std.atomic.Value(bool).init(false);
        self.thread = try std.Thread.spawn(.{}, uploadThread, .{self});
        return self;
    }

    fn uploadThread(self: *AsyncUploader) void {
        // Perform upload in background thread
        // Set result
        self.done.store(true, .release);
    }

    pub fn poll(self: *AsyncUploader) ?UploadResult {
        if (self.done.load(.acquire)) return self.result;
        return null;
    }
};
```

Integration with progress overlay (GTK):
```zig
// NEW: Async upload with non-intrusive progress indicator

// 1. Show progress overlay (NOT writing to terminal!)
priv.progress_bar_overlay.as(gtk.Widget).setVisible(true);

// 2. Start async upload
const async_uploader = try AsyncUploader.start(alloc, &surface.config, path_slice);

// 3. Poll in render loop (glareaRender callback)
//    This keeps UI responsive and progress bar pulsing
if (priv.async_uploader) |uploader| {
    // Pulse progress bar each frame
    priv.progress_bar_overlay.pulse();

    // Check if upload finished
    if (uploader.poll()) |result| {
        // Hide progress overlay
        priv.progress_bar_overlay.as(gtk.Widget).setVisible(false);

        // Paste result to terminal
        switch (result) {
            .success => |url| Clipboard.paste(self, url),
            .failure => |err| log.err("upload failed: {s}", .{err}),
            .fallback => {}, // paste file path instead
        }

        priv.async_uploader = null;
    }
}
```

**Benefits**:
- UI remains responsive during upload
- Terminal stays interactive
- Progress bar pulses smoothly (updated each render frame)
- User can cancel by closing window/tab
- No blocking on network I/O

### 4. UI/UX - Progress Indicator (Non-Intrusive Overlay)

**IMPORTANT**: Progress indicator **MUST NOT** interfere with terminal content!

#### Existing Overlay Infrastructure

Ghostty already has perfect infrastructure for non-intrusive visual feedback:

**GTK** (`src/apprt/gtk/ui/1.2/surface.blp:46-55`):
```blueprint
[overlay]
ProgressBar progress_bar_overlay {
  styles ["osd"]
  visible: false;
  halign: fill;
  valign: start;
}
```

**URL Overlay Reference** (lines 88-116):
```blueprint
[overlay]
Label url_left {
  styles ["background", "url-overlay"]
  visible: false;
  halign: start;
  valign: end;
  label: bind template.mouse-hover-url;
}
```

#### How It Works

1. **BEFORE upload starts**:
   - User drops image file
   - NO text is written to terminal yet
   - Show `progress_bar_overlay` (already exists!)

2. **DURING upload**:
   - Progress bar pulses at top of terminal (OSD style)
   - Terminal content completely untouched
   - User can still interact with terminal
   - Similar to how URL tooltip shows on Ctrl+hover

3. **AFTER upload completes**:
   - Hide progress bar
   - Paste the uploaded URL into terminal (as if user typed it)
   - OR fallback to file path if upload failed

#### Visual Behavior

```
┌─────────────────────────────────────┐
│ [████████░░░░] Uploading image...   │ ← Overlay (does NOT affect terminal)
├─────────────────────────────────────┤
│ $ ls                                │
│ file1.txt  file2.txt                │ ← Terminal content unchanged
│ $ vim config                         │
│ ~                                    │
│ ~                                    │
└─────────────────────────────────────┘
```

**After upload completes:**
```
┌─────────────────────────────────────┐
│ $ ls                                │
│ file1.txt  file2.txt                │
│ $ vim config                         │
│ ~                                    │
│ $ https://i.imgur.com/abc123.png█   │ ← URL pasted into terminal
└─────────────────────────────────────┘
```

#### Implementation

**GTK**: Reuse existing `progress_bar_overlay`
```zig
// Show progress
priv.progress_bar_overlay.as(gtk.Widget).setVisible(true);
priv.progress_bar_overlay.pulse();

// Hide when done
priv.progress_bar_overlay.as(gtk.Widget).setVisible(false);
```

**macOS**: Create similar NSView overlay
```swift
// Show overlay view
uploadIndicator.isHidden = false
uploadIndicator.startAnimation(nil)

// Hide when done
uploadIndicator.isHidden = true
```

### 5. Example Configurations

#### Imgur

```conf
image-upload-enable = true
image-upload-url = https://api.imgur.com/3/image
image-upload-method = post
image-upload-format = multipart
image-upload-field = image
image-upload-header = Authorization: Client-ID YOUR_CLIENT_ID
image-upload-response-path = json:$.data.link
image-upload-max-size = 10
image-upload-timeout = 30
```

#### ImgBB

```conf
image-upload-enable = true
image-upload-url = https://api.imgbb.com/1/upload?key=YOUR_API_KEY
image-upload-method = post
image-upload-format = multipart
image-upload-field = image
image-upload-response-path = json:$.data.url
image-upload-max-size = 32
image-upload-timeout = 60
```

#### Custom Server

```conf
image-upload-enable = true
image-upload-url = https://your-server.com/api/upload
image-upload-method = post
image-upload-format = json
image-upload-field = file
image-upload-header = Authorization: Bearer YOUR_TOKEN
image-upload-header = X-Custom-Header: value
image-upload-response-path = json:$.url
image-upload-fallback = error
```

## Implementation Phases

### Phase 1: Core Functionality (MVP)
- [ ] Add configuration options to `Config.zig`
- [ ] Implement basic `image_upload.zig` module
- [ ] Support POST with multipart/form-data
- [ ] Simple JSONPath response parsing
- [ ] Integrate into GTK drop handler
- [ ] Basic error handling with fallback to file path

### Phase 2: Extended Support
- [ ] macOS implementation
- [ ] Additional upload formats (JSON, binary)
- [ ] Regex response parsing
- [ ] Better error messages and logging
- [ ] Configuration validation

### Phase 3: UX Enhancements
- [ ] Async upload (non-blocking)
- [ ] Progress overlay using existing `progress_bar_overlay` (GTK)
- [ ] Progress overlay for macOS (custom NSView)
- [ ] Optional desktop notifications on success/failure
- [ ] Upload history/cache
- [ ] Retry logic with exponential backoff

### Phase 4: Advanced Features
- [ ] Image optimization before upload (resize, compress)
- [ ] Multiple file upload (drag multiple images)
- [ ] Clipboard image upload (paste image from clipboard)
- [ ] Custom upload plugins/scripts

## Code Organization

```
src/
├── config/
│   └── Config.zig                    # Add new config options
├── image_upload/
│   ├── mod.zig                       # Main module
│   ├── uploader.zig                  # HTTP upload logic
│   ├── parser.zig                    # Response parsing (JSONPath, regex)
│   ├── formats/
│   │   ├── multipart.zig
│   │   ├── json.zig
│   │   └── binary.zig
│   └── async.zig                     # Async upload support
├── file_type.zig                     # Already exists - reuse
├── apprt/
│   └── gtk/
│       └── class/
│           └── surface.zig           # Modify dtDrop
└── os/
    └── shell.zig                      # Already exists - reuse
```

## Testing Strategy

### Unit Tests
- Configuration parsing
- Image type detection
- Response URL extraction
- Error handling

### Integration Tests
- Mock HTTP server for upload tests
- Test with different API formats
- Verify fallback behavior
- Test async upload cancellation

### Manual Testing
- Test with Imgur/ImgBB
- Test with custom server
- Drag different image formats
- Test large files
- Test network failures

## Security Considerations

1. **HTTPS Only**: Warn or reject non-HTTPS endpoints (optional config)
2. **File Size Limits**: Enforce `image-upload-max-size`
3. **Timeout Protection**: Always set `image-upload-timeout`
4. **Header Sanitization**: Validate custom headers
5. **URL Validation**: Parse and validate URLs before upload
6. **No Auto-Execute**: Uploaded URLs are pasted as text, not executed
7. **Maintain Clipboard Protection**: Use existing `clipboard-paste-protection`

## Performance Considerations

- **Memory**: Stream large files instead of reading entirely into memory
- **Network**: Use connection pooling for multiple uploads
- **UI Blocking**: Implement async upload to keep UI responsive
- **Caching**: Consider caching uploads (optional feature)

## Backwards Compatibility

- **Default Disabled**: `image-upload-enable = false` by default
- **Graceful Degradation**: Falls back to path paste if upload fails
- **No Breaking Changes**: Existing drag & drop behavior unchanged when disabled

## Documentation

Add to `website/docs/config/`:

```markdown
## Image Upload

Ghostty can automatically upload images when dropped into the terminal
and paste the resulting URL instead of the local file path.

### Configuration

See `image-upload-*` options in the configuration reference.

### Supported Services

- Imgur
- ImgBB
- Custom servers with JSON/multipart APIs

### Example: Imgur Setup

1. Get API key from https://api.imgur.com/oauth2/addclient
2. Add to config:
   ```
   image-upload-enable = true
   image-upload-url = https://api.imgur.com/3/image
   image-upload-header = Authorization: Client-ID YOUR_ID
   ```
```

## Maintenance & Fork Sync Strategy

### Localized Changes
All changes are confined to:
1. New module: `src/image_upload/` (completely new, no conflicts)
2. Config additions: `src/config/Config.zig` (append-only, minimal conflicts)
3. Drop handler modifications: `src/apprt/*/surface.*` (small, localized changes)

### Merge Conflict Mitigation
- Config changes at end of struct (append-only pattern)
- Drop handler changes clearly marked with comments
- Separate module reduces coupling with core code

### Testing After Merge
```bash
# After pulling from upstream:
zig build test -Dfilter=image_upload
# Test drop functionality manually
```

## Alternative Approaches Considered

### 1. External Script Integration
**Idea**: Call external script for upload via config option
**Pros**: Maximum flexibility, no HTTP code in Ghostty
**Cons**: Platform-specific, harder to configure, less integrated

### 2. OSC Sequence
**Idea**: Extend terminal with OSC sequence for upload
**Pros**: Clean separation, programs can trigger uploads
**Cons**: Requires programs to support it, doesn't solve drag & drop

### 3. Plugin System
**Idea**: General plugin system for extensibility
**Pros**: Solves many extension needs
**Cons**: Major architectural change, out of scope

**Decision**: Built-in configurable upload is the best balance of
usability, maintainability, and integration.

## Questions for PR Review

1. Should we support GET requests or only POST?
2. Should HTTPS be mandatory or just recommended?
3. Should we include basic auth support (username:password)?
4. Should response parsing support XML in addition to JSON?
5. Should there be a way to test configuration (dry-run)?
6. Should uploads be logged for debugging?

## Conclusion

This design provides a professional, maintainable solution for automatic
image uploads in Ghostty. The implementation is:

- **Non-invasive**: Localized changes, easy to sync with upstream
- **Configurable**: Supports multiple APIs and custom endpoints
- **Secure**: Maintains existing security mechanisms
- **User-friendly**: Sensible defaults with clear error handling
- **Extensible**: Easy to add new formats and features

The phased approach allows incremental implementation and testing,
with the MVP providing immediate value while leaving room for
future enhancements.
