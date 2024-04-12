import { ZigJS, predefined } from '../src';

test('predefined values', () => {
  const st = new ZigJS();
  expect(st.loadValue(0)).toBeNaN();
  expect(st.loadValue(1)).toEqual(null);
  expect(st.loadValue(2)).toEqual(true);
  expect(st.loadValue(3)).toEqual(false);
  expect(st.loadValue(4)).toEqual(undefined);
  expect(st.loadValue(5)).toEqual(globalThis);
});

test('valueGet', () => {
  const st = new ZigJS();
  const obj = st.importObject();
  const f = obj["zig-js"].valueGet;

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string
  const key = "__zigjs_number";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Write our key into the global value
  globalThis[key] = 1234;

  // Read it
  f(64, predefined.globalThis, 0, write.written ?? 0);
  expect(view.getFloat64(64, true)).toEqual(1234);
});

test('valueGet with shared memory', () => {
  const st = new ZigJS();
  const obj = st.importObject();
  const f = obj["zig-js"].valueGet;

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 10, shared: true });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string
  const key = "__zigjs_number";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Write our key into the global value
  globalThis[key] = 1234;

  // Read it
  f(64, predefined.globalThis, 0, write.written ?? 0);
  expect(view.getFloat64(64, true)).toEqual(1234);
});

test('valueGet: runtime', () => {
  const st = new ZigJS();
  const obj = st.importObject();
  const f = obj["zig-js"].valueGet;

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string
  const key = "memory";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Read it
  f(64, predefined.runtime, 0, write.written ?? 0);
  expect(st.loadValue(st.loadRefId(64))).toEqual(memory);
});

test('valueGet: string', () => {
  const st = new ZigJS();
  const obj = st.importObject();

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string
  const key = "__zigjs_string";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Write our key into the global value
  globalThis[key] = "橋本";

  // Read it
  const refAddr = 64;
  const f = obj["zig-js"].valueGet;
  f(refAddr, predefined.globalThis, 0, write.written ?? 0);
  expect(st.loadRef(refAddr)).toEqual("橋本");

  // Read the string length
  {
    const stringLen = obj["zig-js"].valueStringLen;
    const len = stringLen(st.loadRefId(refAddr));
    expect(len).not.toBeNaN();
    expect(len).toEqual(6);
  }

  // Copy the string into memory
  const offset = 12;
  {
    const stringCopy = obj["zig-js"].valueStringCopy;
    stringCopy(st.loadRefId(refAddr), offset, 64);
  }

  // Read it
  const str = new TextDecoder('utf-8').decode(new DataView(memory.buffer, 12, 6));
  expect(str).toEqual("橋本");
});

test('valueSet: number', () => {
  const st = new ZigJS();
  const obj = st.importObject();
  const f = obj["zig-js"].valueSet;

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string
  const key = "__zigjs_number";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Write our argument
  const refAddr = 64;
  view.setFloat64(refAddr, 42, true);

  // Write our key into the global value
  globalThis[key] = 12;

  // Set it
  f(predefined.globalThis, 0, write.written ?? 0, refAddr);
  expect(globalThis[key]).toEqual(42);
});

test('valueSet: ref', () => {
  const st = new ZigJS();
  const obj = st.importObject();
  const f = obj["zig-js"].valueSet;

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string
  const key = "__zigjs_boolean";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Write our argument
  const refAddr = 64;
  st.storeValue(refAddr, true);

  // Write our key into the global value
  globalThis[key] = false;

  // Set it
  f(predefined.globalThis, 0, write.written ?? 0, refAddr);
  expect(globalThis[key]).toEqual(true);
});

test('valueStringCreate', () => {
  const st = new ZigJS();
  const obj = st.importObject();

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Write our string into memory
  const value = "hello, world!";
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(value, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Read it
  let f = obj["zig-js"].valueStringCreate;
  const refAddr = 64;
  f(refAddr, 0, write.written ?? 0);
  expect(st.loadValue(st.loadRefId(refAddr))).toEqual(value);
});

test('valueObjectCreate', () => {
  const st = new ZigJS();
  const obj = st.importObject();

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Read it
  let f = obj["zig-js"].valueObjectCreate;
  const refAddr = 64;
  f(refAddr);
  expect(st.loadValue(st.loadRefId(refAddr))).toEqual({});
});

test('valueNew', () => {
  const st = new ZigJS();
  const obj = st.importObject();

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Set our function
  const key = "Uint8Array";

  // Write our string
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Construct
  const funcAddr = 64;
  const f = obj["zig-js"].valueGet;
  f(funcAddr, predefined.globalThis, 0, write.written ?? 0);

  // Setup our args
  view.setFloat64(0, 24, true);

  // Call it!
  const resultAddr = 0;
  obj["zig-js"].valueNew(
    resultAddr,
    st.loadRefId(funcAddr),
    0,
    1,
  );

  const arr = st.loadRef(resultAddr);
  expect(arr.length).toEqual(24);
});

test('funcApply', () => {
  const st = new ZigJS();
  const obj = st.importObject();

  // Set our memory
  const memory = new WebAssembly.Memory({ initial: 1 });
  const view = new DataView(memory.buffer);
  st.memory = memory;

  // Set our function
  const key = "__zigjs_func";
  globalThis[key] = (x: number): number => x * 2;

  // Write our string
  const encoder = new TextEncoder();
  const write = encoder.encodeInto(key, new Uint8Array(memory.buffer));
  expect(write.written).toBeGreaterThan(0);

  // Read the func
  const funcAddr = 64;
  const f = obj["zig-js"].valueGet;
  f(funcAddr, predefined.globalThis, 0, write.written ?? 0);
  expect(st.loadValue(st.loadRefId(funcAddr))).toBeInstanceOf(Function);

  // Setup our args
  view.setFloat64(0, 24, true);

  // Call it!
  const resultAddr = 0;
  obj["zig-js"].funcApply(
    resultAddr,
    st.loadRefId(funcAddr),
    predefined.undefined,
    0,
    1,
  );
  expect(st.loadRef(resultAddr)).toEqual(48);
});

// We need to extend our global value for test keys
declare global {
  var __zigjs_boolean: boolean;
  var __zigjs_number: number;
  var __zigjs_string: string;
  var __zigjs_func: any;
}
