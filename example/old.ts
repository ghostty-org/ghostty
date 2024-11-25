import { zjs } from "./imports";

export function old(results) {
  const {
    atlas_clear,
    atlas_debug_canvas,
    atlas_free,
    atlas_grow,
    atlas_new,
    atlas_reserve,
    atlas_set,
    config_finalize,
    config_free,
    config_load_string,
    config_new,
    deferred_face_free,
    deferred_face_load,
    deferred_face_new,
    face_debug_canvas,
    face_free,
    face_new,
    face_render_glyph,
    free,
    malloc,
    shaper_free,
    shaper_new,
    shaper_test,
    collection_new,
    collection_add_deferred_face,
    shared_grid_new,
    shared_grid_atlas_grayscale,
    shared_grid_atlas_color,
    shared_grid_index_for_codepoint,
    shared_grid_render_glyph,
    run,
  } = results.instance.exports;


  // Helpers
  const makeStr = (str) => {
    const utf8 = new TextEncoder().encode(str);
    const ptr = malloc(utf8.byteLength);
    new Uint8Array(zjs.memory.buffer, ptr).set(utf8);
    return { ptr: ptr, len: utf8.byteLength };
  };
  // Create our config
  const config_str = makeStr("font-family = monospace");

  const config = config_new();
  config_load_string(config, config_str);
  config_finalize(config);
  free(config_str.ptr);
  // Create our atlas
  // const atlas = atlas_new(512, 0 /* grayscale */);

  // Create some memory for our string
  const font_name = makeStr("monospace");

  // Initialize our deferred face
  // const df = deferred_face_new(font_ptr, font.byteLength, 0 /* text */);
  //deferred_face_load(df, 72 /* size */);
  //const face = deferred_face_face(df);

  // Initialize our font face
  //const face = face_new(font_ptr, font.byteLength, 72 /* size in px */);
  //free(font_ptr);

  // Create our group
  const collection = collection_new(32);
  collection_add_deferred_face(
    collection,
    0 /* regular */,
    deferred_face_new(font_name.ptr, font_name.len, 0 /* text */),
  );
  collection_add_deferred_face(
    collection,
    0 /* regular */,
    deferred_face_new(font_name.ptr, font_name.len, 1 /* emoji */),
  );
  const grid = shared_grid_new(collection);

  // Initialize our sprite font, without this we just use the browser.
  // group_init_sprite_face(group);

  // // Create our group cache
  // const group_cache = group_cache_new(group);

  // Render a glyph
  for (let i = 33; i <= 126; i++) {
    const font_idx = shared_grid_index_for_codepoint(grid, i, 0, -1);
    shared_grid_render_glyph(grid, font_idx, i, 0);
    //face_render_glyph(face, atlas, i);
  }
  //
  const emoji = ["🐏", "🌞", "🌚", "🍱", "💿", "🐈", "📃", "📀", "🕡", "🙃"];
  for (let i = 0; i < emoji.length; i++) {
    const cp = emoji[i].codePointAt(0);
    const font_idx = shared_grid_index_for_codepoint(grid, cp, 0, -1 /* best choice */);
    shared_grid_render_glyph(grid, font_idx, cp, 0);
  }

  for (let i = 0x2500; i <= 0x257f; i++) {
    const font_idx = shared_grid_index_for_codepoint(grid, i, 0, -1);
    shared_grid_render_glyph(grid, font_idx, i, 0);
  }
  for (let i = 0x2580; i <= 0x259f; i++) {
    const font_idx = shared_grid_index_for_codepoint(grid, i, 0, -1);
    shared_grid_render_glyph(grid, font_idx, i, 0);
  }
  for (let i = 0x2800; i <= 0x28ff; i++) {
    const font_idx = shared_grid_index_for_codepoint(grid, i, 0, -1);
    shared_grid_render_glyph(grid, font_idx, i, 0);
  }
  for (let i = 0x1fb00; i <= 0x1fb3b; i++) {
    const font_idx = shared_grid_index_for_codepoint(grid, i, 0, -1);
    shared_grid_render_glyph(grid, font_idx, i, 0);
  }
  for (let i = 0x1fb3c; i <= 0x1fb6b; i++) {
    const font_idx = shared_grid_index_for_codepoint(grid, i, 0, -1);
    shared_grid_render_glyph(grid, font_idx, i, 0);
  }

  //face_render_glyph(face, atlas, "橋".codePointAt(0));
  //face_render_glyph(face, atlas, "p".codePointAt(0));

  // Debug our canvas
  //face_debug_canvas(face);

  // Let's try shaping
  const shaper = shaper_new(120);
  //const input = makeStr("hello🐏");
  const input = makeStr("M_yhelloaaaaaaaaa\n🐏\n👍🏽\nM_ghostty");
  shaper_test(shaper, grid, input.ptr, input.len);

  const cp = 1114112;
  const font_idx = shared_grid_index_for_codepoint(
    grid,
    cp,
    0,
    -1 /* best choice */,
  );
  shared_grid_render_glyph(grid, font_idx, cp, -1);

  // Debug our atlas canvas
  {
    const atlas = shared_grid_atlas_grayscale(grid);
    const id = atlas_debug_canvas(atlas);
    document.getElementById("atlas-canvas").append(zjs.deleteValue(id));
  }

  {
    const atlas = shared_grid_atlas_color(grid);
    const id = atlas_debug_canvas(atlas);
    document.getElementById("atlas-color-canvas").append(zjs.deleteValue(id));
  }

  //face_free(face);
}
