import { importObject, zjs } from "./imports";

onmessage = async (e) => {
  console.log("module received from main thread");
  const [memory, instance] = e.data;
  importObject.env.memory = memory;
const url = new URL("ghostty-wasm.wasm", import.meta.url);
  const results = await WebAssembly.instantiateStreaming(fetch(url), importObject)
  zjs.memory = memory;
  results.instance.exports.wasi_thread_start(100, instance);
};
