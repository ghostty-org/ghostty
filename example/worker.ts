import { importObject, setFiles, setMainThread, setStdin, zjs } from "./imports";

onmessage = async (e) => {
  console.log("module received from main thread");
  const [memory, instance, stdin, wasmModule, files] = e.data;
  console.log(wasmModule)
  setStdin(stdin);
  setMainThread(false);
  setFiles(files);
  importObject.env.memory = memory;
  const results = await WebAssembly.instantiate(wasmModule, importObject);
  zjs.memory = memory;
  results.exports.wasi_thread_start(100, instance);
};
