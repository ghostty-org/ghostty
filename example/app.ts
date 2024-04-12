import { ZigJS } from "zig-js";

const zjs = new ZigJS();
const importObject = {
  module: {},
  env: {
    memory: new WebAssembly.Memory({
      initial: 25,
      maximum: 1024,
      shared: true,
    }),
    log: (ptr: number, len: number) => {
      const arr = new Uint8ClampedArray(zjs.memory.buffer, ptr, len);
      const data = arr.slice();
      const str = new TextDecoder("utf-8").decode(data);
      console.log(str);
    },
  },

  ...zjs.importObject(),
};

const url = new URL("ghostty-wasm.wasm", import.meta.url);
fetch(url.href)
  .then((response) => response.arrayBuffer())
  .then((bytes) => WebAssembly.instantiate(bytes, importObject))
  .then((results) => {
    const memory = importObject.env.memory;
    const {
      malloc,
      free,
      config_new,
      config_free,
      config_load_string,
      config_finalize,
      face_new,
      face_free,
      face_render_glyph,
      face_debug_canvas,
      deferred_face_new,
      deferred_face_free,
      deferred_face_load,
      deferred_face_face,
      group_new,
      group_free,
      group_add_face,
      group_init_sprite_face,
      group_index_for_codepoint,
      group_render_glyph,
      group_cache_new,
      group_cache_free,
      group_cache_index_for_codepoint,
      group_cache_render_glyph,
      group_cache_atlas_greyscale,
      group_cache_atlas_color,
      atlas_new,
      atlas_free,
      atlas_debug_canvas,
      shaper_new,
      shaper_free,
      shaper_test,
    } = results.instance.exports;
    // Give us access to the zjs value for debugging.
    globalThis.zjs = zjs;
    console.log(zjs);

    // Initialize our zig-js memory
    zjs.memory = memory;

    // Helpers
    const makeStr = (str) => {
      const utf8 = new TextEncoder().encode(str);
      const ptr = malloc(utf8.byteLength);
      new Uint8Array(memory.buffer, ptr).set(utf8);
      return { ptr: ptr, len: utf8.byteLength };
    };

    // Create our config
    const config = config_new();
    const config_str = makeStr("font-family = monospace");
    config_load_string(config, config_str.ptr, config_str.len);
    config_finalize(config);
    free(config_str.ptr);

    // Create our atlas
    // const atlas = atlas_new(512, 0 /* greyscale */);

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
    const group = group_new(32 /* size */);
    group_add_face(
      group,
      0 /* regular */,
      deferred_face_new(font_name.ptr, font_name.len, 0 /* text */)
    );
    group_add_face(
      group,
      0 /* regular */,
      deferred_face_new(font_name.ptr, font_name.len, 1 /* emoji */)
    );

    // Initialize our sprite font, without this we just use the browser.
    group_init_sprite_face(group);

    // Create our group cache
    const group_cache = group_cache_new(group);

    // Render a glyph
    // for (let i = 33; i <= 126; i++) {
    //   const font_idx = group_cache_index_for_codepoint(group_cache, i, 0, -1);
    //   group_cache_render_glyph(group_cache, font_idx, i, 0);
    //   //face_render_glyph(face, atlas, i);
    // }
    //
    // const emoji = ["🐏","🌞","🌚","🍱","💿","🐈","📃","📀","🕡","🙃"];
    // for (let i = 0; i < emoji.length; i++) {
    //   const cp = emoji[i].codePointAt(0);
    //   const font_idx = group_cache_index_for_codepoint(group_cache, cp, 0, -1 /* best choice */);
    //   group_cache_render_glyph(group_cache, font_idx, cp, 0);
    // }

    for (let i = 0x2500; i <= 0x257f; i++) {
      const font_idx = group_cache_index_for_codepoint(group_cache, i, 0, -1);
      group_cache_render_glyph(group_cache, font_idx, i, 0);
    }
    for (let i = 0x2580; i <= 0x259f; i++) {
      const font_idx = group_cache_index_for_codepoint(group_cache, i, 0, -1);
      group_cache_render_glyph(group_cache, font_idx, i, 0);
    }
    for (let i = 0x2800; i <= 0x28ff; i++) {
      const font_idx = group_cache_index_for_codepoint(group_cache, i, 0, -1);
      group_cache_render_glyph(group_cache, font_idx, i, 0);
    }
    for (let i = 0x1fb00; i <= 0x1fb3b; i++) {
      const font_idx = group_cache_index_for_codepoint(group_cache, i, 0, -1);
      group_cache_render_glyph(group_cache, font_idx, i, 0);
    }
    for (let i = 0x1fb3c; i <= 0x1fb6b; i++) {
      const font_idx = group_cache_index_for_codepoint(group_cache, i, 0, -1);
      group_cache_render_glyph(group_cache, font_idx, i, 0);
    }

    //face_render_glyph(face, atlas, "橋".codePointAt(0));
    //face_render_glyph(face, atlas, "p".codePointAt(0));

    // Debug our canvas
    //face_debug_canvas(face);

    // Let's try shaping
    const shaper = shaper_new(120);
    //const input = makeStr("hello🐏");
    const input = makeStr("hello🐏👍🏽");
    shaper_test(shaper, group_cache, input.ptr, input.len);

    const cp = 1114112;
    const font_idx = group_cache_index_for_codepoint(
      group_cache,
      cp,
      0,
      -1 /* best choice */
    );
    group_cache_render_glyph(group_cache, font_idx, cp, -1);

    // Debug our atlas canvas
    {
      const atlas = group_cache_atlas_greyscale(group_cache);
      const id = atlas_debug_canvas(atlas);
      document.getElementById("atlas-canvas").append(zjs.deleteValue(id));
    }

    {
      const atlas = group_cache_atlas_color(group_cache);
      const id = atlas_debug_canvas(atlas);
      document.getElementById("atlas-color-canvas").append(zjs.deleteValue(id));
    }

    //face_free(face);
  });
