const std = @import("std");
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const renderer = @import("../../renderer.zig");

fn durationMs(start: std.Io.Timestamp, end: std.Io.Timestamp) f32 {
    const ns = start.durationTo(end).toNanoseconds();
    return @as(f32, @floatFromInt(@max(ns, 0))) / std.time.ns_per_ms;
}

pub fn drawFrameTimings(history: *renderer.FrameTimings, open: bool) void {
    if (!open) return;

    var frames: [renderer.FrameTimings.capacity]renderer.FrameTimings.Frame = undefined;
    const len = history.snapshot(&frames);
    if (len == 0) {
        cimgui.c.ImGui_Text("No frame times recorded yet.");
        return;
    }

    var data: [renderer.FrameTimings.capacity]f32 = undefined;
    var sum_frame: f32 = 0;
    var max_frame: f32 = 0;
    for (frames[0..len], 0..) |frame, i| {
        data[i] = durationMs(frame.start, frame.end);
        sum_frame += data[i];
        max_frame = @max(max_frame, data[i]);
    }

    const count: f32 = @floatFromInt(len);
    cimgui.c.ImGui_SeparatorText("Performance");
    cimgui.c.ImGui_PlotLines("Frame time (ms)", @ptrCast(&data), @intCast(len));
    if (!cimgui.c.ImGui_BeginTable(
        "frame-timings",
        2,
        cimgui.c.ImGuiTableFlags_Borders |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupColumn("Metric", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Value", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableHeadersRow();

    if (len > 1) {
        const span_ns = frames[0].end.durationTo(frames[len - 1].end).toNanoseconds();
        if (span_ns > 0) {
            const fps = @as(f64, @floatFromInt(len - 1)) * std.time.ns_per_s /
                @as(f64, @floatFromInt(span_ns));
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableNextColumn();
            cimgui.c.ImGui_TextUnformatted("Average FPS");
            _ = cimgui.c.ImGui_TableNextColumn();
            cimgui.c.ImGui_Text("%8.2f", fps);

            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableNextColumn();
            cimgui.c.ImGui_TextUnformatted("Average frame interval");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Reciprocal of average FPS, based on completed frames. " ++
                "This is only the display frame budget when output is steady and vsynced.");
            _ = cimgui.c.ImGui_TableNextColumn();
            cimgui.c.ImGui_Text("%8.3f ms", 1000.0 / fps);
        }
    }
    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableNextColumn();
    cimgui.c.ImGui_TextUnformatted("Average frame time");
    _ = cimgui.c.ImGui_TableNextColumn();
    cimgui.c.ImGui_Text("%8.3f ms", @as(f64, sum_frame / count));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableNextColumn();
    cimgui.c.ImGui_TextUnformatted("Maximum frame time");
    _ = cimgui.c.ImGui_TableNextColumn();
    cimgui.c.ImGui_Text("%8.3f ms", @as(f64, max_frame));
}

/// Renderer information inspector widget.
pub const Info = struct {
    features: renderer.Overlay.FeatureSet,

    pub const empty: Info = .{
        .features = .{},
    };

    /// Draw the renderer info window.
    pub fn draw(
        self: *Info,
        open: bool,
    ) void {
        if (!open) return;

        cimgui.c.ImGui_SetNextItemOpen(true, cimgui.c.ImGuiCond_Once);
        if (!cimgui.c.ImGui_CollapsingHeader("Overlays", cimgui.c.ImGuiTreeNodeFlags_None)) return;

        cimgui.c.ImGui_SeparatorText("Hyperlinks");
        self.overlayHyperlinks();
        cimgui.c.ImGui_SeparatorText("Semantic Prompts");
        self.overlaySemanticPrompts();
    }

    fn overlayHyperlinks(self: *Info) void {
        _ = cimgui.c.ImGui_Checkbox("Overlay Hyperlinks", &self.features.highlight_hyperlinks);
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("When enabled, highlights OSC8 hyperlinks.");
    }

    fn overlaySemanticPrompts(self: *Info) void {
        _ = cimgui.c.ImGui_Checkbox("Overlay Semantic Prompts", &self.features.semantic_prompts);
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("When enabled, highlights OSC 133 semantic prompts.");

        // Help
        cimgui.c.ImGui_Indent();
        defer cimgui.c.ImGui_Unindent();

        cimgui.c.ImGui_TextDisabled("Colors:");

        const prompt_rgb = renderer.Overlay.Color.semantic_prompt.rgb();
        const input_rgb = renderer.Overlay.Color.semantic_input.rgb();
        const prompt_col: cimgui.c.ImVec4 = .{
            .x = @as(f32, @floatFromInt(prompt_rgb.r)) / 255.0,
            .y = @as(f32, @floatFromInt(prompt_rgb.g)) / 255.0,
            .z = @as(f32, @floatFromInt(prompt_rgb.b)) / 255.0,
            .w = 1.0,
        };
        const input_col: cimgui.c.ImVec4 = .{
            .x = @as(f32, @floatFromInt(input_rgb.r)) / 255.0,
            .y = @as(f32, @floatFromInt(input_rgb.g)) / 255.0,
            .z = @as(f32, @floatFromInt(input_rgb.b)) / 255.0,
            .w = 1.0,
        };

        _ = cimgui.c.ImGui_ColorButton("##prompt_color", prompt_col, cimgui.c.ImGuiColorEditFlags_NoTooltip);
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_Text("Prompt");

        _ = cimgui.c.ImGui_ColorButton("##input_color", input_col, cimgui.c.ImGuiColorEditFlags_NoTooltip);
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_Text("Input");
    }
};
