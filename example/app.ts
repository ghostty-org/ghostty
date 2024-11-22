import { importObject, zjs } from "./imports";
import { old } from "./old";

const url = new URL("ghostty-wasm.wasm", import.meta.url);
fetch(url.href)
  .then((response) => response.arrayBuffer())
  .then((bytes) => WebAssembly.instantiate(bytes, importObject))
  .then((results) => {
    const memory = importObject.env.memory;
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
    const config_str = makeStr("font-family = monospace\nfont-size 32\n");
    old(results);
    run(config_str.ptr, config_str.len);
  })
