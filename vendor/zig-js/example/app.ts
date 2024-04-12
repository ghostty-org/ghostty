import { ZigJS } from 'zig-js';

export function add(a: number, b: number): number {
  return a + b;
}

const zjs = new ZigJS();
const importObject = {
  module: {},
  env: {},
  ...zjs.importObject(),
};

const url = new URL('example.wasm', import.meta.url);
fetch(url.href).then(response =>
  response.arrayBuffer()
).then(bytes =>
  WebAssembly.instantiate(bytes, importObject)
).then(results => {
  const { memory, alert, set_title } = results.instance.exports;
  zjs.memory = memory;

  // Call whatever example you want:
  set_title();
  //alert();
});
