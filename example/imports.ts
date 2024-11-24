import { ZigJS } from "zig-js/src/index.ts";
import {
  WASI_ESUCCESS,
  WASI_EBADF,
  WASI_EINVAL,
  WASI_ENOSYS,
  WASI_EPERM,
  //WASI_ENOTCAPABLE,
  WASI_FILETYPE_UNKNOWN,
  WASI_FILETYPE_BLOCK_DEVICE,
  WASI_FILETYPE_CHARACTER_DEVICE,
  WASI_FILETYPE_DIRECTORY,
  WASI_FILETYPE_REGULAR_FILE,
  WASI_FILETYPE_SOCKET_STREAM,
  WASI_FILETYPE_SYMBOLIC_LINK,
  WASI_FILETYPE,
  WASI_FDFLAG_APPEND,
  WASI_FDFLAG_DSYNC,
  WASI_FDFLAG_NONBLOCK,
  WASI_FDFLAG_RSYNC,
  WASI_FDFLAG_SYNC,
  WASI_RIGHT_FD_DATASYNC,
  WASI_RIGHT_FD_READ,
  WASI_RIGHT_FD_SEEK,
  WASI_RIGHT_FD_FDSTAT_SET_FLAGS,
  WASI_RIGHT_FD_SYNC,
  WASI_RIGHT_FD_TELL,
  WASI_RIGHT_FD_WRITE,
  WASI_RIGHT_FD_ADVISE,
  WASI_RIGHT_FD_ALLOCATE,
  WASI_RIGHT_PATH_CREATE_DIRECTORY,
  WASI_RIGHT_PATH_CREATE_FILE,
  WASI_RIGHT_PATH_LINK_SOURCE,
  WASI_RIGHT_PATH_LINK_TARGET,
  WASI_RIGHT_PATH_OPEN,
  WASI_RIGHT_FD_READDIR,
  WASI_RIGHT_PATH_READLINK,
  WASI_RIGHT_PATH_RENAME_SOURCE,
  WASI_RIGHT_PATH_RENAME_TARGET,
  WASI_RIGHT_PATH_FILESTAT_GET,
  WASI_RIGHT_PATH_FILESTAT_SET_SIZE,
  WASI_RIGHT_PATH_FILESTAT_SET_TIMES,
  WASI_RIGHT_FD_FILESTAT_GET,
  WASI_RIGHT_FD_FILESTAT_SET_SIZE,
  WASI_RIGHT_FD_FILESTAT_SET_TIMES,
  WASI_RIGHT_PATH_SYMLINK,
  WASI_RIGHT_PATH_REMOVE_DIRECTORY,
  WASI_RIGHT_POLL_FD_READWRITE,
  WASI_RIGHT_PATH_UNLINK_FILE,
  RIGHTS_BLOCK_DEVICE_BASE,
  RIGHTS_BLOCK_DEVICE_INHERITING,
  RIGHTS_CHARACTER_DEVICE_BASE,
  RIGHTS_CHARACTER_DEVICE_INHERITING,
  RIGHTS_REGULAR_FILE_BASE,
  RIGHTS_REGULAR_FILE_INHERITING,
  RIGHTS_DIRECTORY_BASE,
  RIGHTS_DIRECTORY_INHERITING,
  RIGHTS_SOCKET_BASE,
  RIGHTS_SOCKET_INHERITING,
  RIGHTS_TTY_BASE,
  RIGHTS_TTY_INHERITING,
  WASI_CLOCK_MONOTONIC,
  WASI_CLOCK_PROCESS_CPUTIME_ID,
  WASI_CLOCK_REALTIME,
  WASI_CLOCK_THREAD_CPUTIME_ID,
  WASI_EVENTTYPE_CLOCK,
  WASI_EVENTTYPE_FD_READ,
  WASI_EVENTTYPE_FD_WRITE,
  WASI_FILESTAT_SET_ATIM,
  WASI_FILESTAT_SET_ATIM_NOW,
  WASI_FILESTAT_SET_MTIM,
  WASI_FILESTAT_SET_MTIM_NOW,
  WASI_O_CREAT,
  WASI_O_DIRECTORY,
  WASI_O_EXCL,
  WASI_O_TRUNC,
  WASI_PREOPENTYPE_DIR,
  WASI_STDIN_FILENO,
  WASI_STDOUT_FILENO,
  WASI_STDERR_FILENO,
  ERROR_MAP,
  SIGNAL_MAP,
  WASI_WHENCE_CUR,
  WASI_WHENCE_END,
  WASI_WHENCE_SET,
} from "./wasi";
const textDecoder = new TextDecoder("utf-8");
let stdin = new SharedArrayBuffer(1024);
export function setStdin(buf: SharedArrayBuffer) {
  stdin = buf;
}
let bytes: null | Uint8ClampedArray = null
function perfNow() {
  return performance.now() + performance.timeOrigin;
}
function readStdin() {
  const len = new Int32Array(stdin);
  if (len[0] == 0) {
    Atomics.wait(len, 0, 0, 1000);
  }
  const length = len[0];
  console.error("stdin", length);
  if (length === 0) {
    bytes = null;
    return;
  }
  bytes = new Uint8ClampedArray(stdin, 4, length).slice();
  console.log(textDecoder.decode(bytes));
  Atomics.store(len, 0, 0);
  Atomics.notify(len, 0);
}
function sleep(ms: number) {
  const buf = new SharedArrayBuffer(4);
  const view = new Int32Array(buf);
  view[0] = 1;
  Atomics.wait(view, 0, 1, ms);


}
let wasmModule;
export function setWasmModule(mod) {
  wasmModule = mod;
}
let mainThread = true;
export function setMainThread(isMain) {
  mainThread = isMain;
}
let gl: WebGL2RenderingContext;
export function setGl(l) {
  gl = l;
}

export const zjs = new ZigJS();
globalThis.fontCanvas = new OffscreenCanvas(0, 0);
// window.fontContext = () => {
//   const ctx = fontCanvas.getContext("2d");
//   ctx.willReadFrequently = true;
//   return ctx;
// }
try {
  const $webgl = document.getElementById("main-canvas");
  let webgl2Supported = typeof WebGL2RenderingContext !== "undefined";

  let webglOptions = {
    alpha: false,
    antialias: true,
    depth: 32,
    failIfMajorPerformanceCaveat: false,
    powerPreference: "default",
    premultipliedAlpha: true,
    preserveDrawingBuffer: true,
  };

  if (webgl2Supported) {
    gl = $webgl.getContext("webgl2", webglOptions);
    if (!gl) {
      throw new Error("The browser supports WebGL2, but initialization failed.");
    }
  }
} catch (e) { console.error(e) }

// OpenGL operates on numeric IDs while WebGL on objects. The following is a
// hack made to allow keeping current API on the native side while resolving IDs
// to objects in JS. Because the values of those IDs don't really matter, there
// is a shared counter.
let id = 1;
const getId = () => {
  id += 1;
  return id;
};

const glShaders = new Map();
const glPrograms = new Map();
const glVertexArrays = new Map();
const glBuffers = new Map();
const glFrameBuffers = new Map();
const glTextures = new Map();
const glUniformLocations = new Map();

const glViewport = (x, y, width, height) => {
  gl.viewport(x, y, width, height);
};

const glClearColor = (r, g, b, a) => {
  gl.clearColor(r, g, b, a);
};

const glEnable = (value) => {
  gl.enable(value);
};

const glDisable = (value) => {
  gl.disable(value);
};

const glDepthFunc = (value) => {
  gl.depthFunc(value);
};

const glBlendFunc = (sFactor, dFactor) => {
  gl.blendFunc(sFactor, dFactor);
};

const glClear = (value) => {
  gl.clear(value);
};

const glGetAttribLocation = (programId, pointer, length) => {
  const name = zjs.loadString(pointer, length);
  return gl.getAttribLocation(glPrograms.get(programId), name);
};

const glGetUniformLocation = (programId, pointer) => {
  const str = new Uint8Array(zjs.memory.buffer, pointer);
  let i = 0;
  while (str[i] !== 0) i++;
  const name = textDecoder.decode(str.slice(0, i));
  const value = gl.getUniformLocation(glPrograms.get(programId), name);
  const id = getId();
  glUniformLocations.set(id, value);
  return id;
};

const glUniform4fv = (locationId, x, y, z, w) => {
  gl.uniform4fv(glUniformLocations.get(locationId), [x, y, z, w]);
};

const glUniform2f = (locationId, x, y) => {
  gl.uniform2f(glUniformLocations.get(locationId), x, y);
};

const glUniformMatrix4fv = (locationId, length, transpose, pointer) => {
  const floats = new Float32Array(zjs.memory.buffer, pointer, length * 16);
  gl.uniformMatrix4fv(glUniformLocations.get(locationId), transpose, floats);
};

const glUniform1i = (locationId, value) => {
  gl.uniform1i(glUniformLocations.get(locationId), value);
};

const glUniform1f = (locationId, value) => {
  gl.uniform1f(glUniformLocations.get(locationId), value);
};

const glCreateBuffer = () => {
  const id = getId();
  glBuffers.set(id, gl.createBuffer());
  return id;
};

const glGenBuffers = (number, pointer) => {
  const buffers = new Uint32Array(zjs.memory.buffer, pointer, number);
  for (let n = 0; n < number; n++) {
    const b = glCreateBuffer();
    buffers[n] = b;
  }
};

const glAttachShader = (program, shader) => {
  gl.attachShader(glPrograms.get(program), glShaders.get(shader));
};

const glDetachShader = (program, shader) => {
  gl.detachShader(glPrograms.get(program), glShaders.get(shader));
};

const glDeleteProgram = (id) => {
  gl.deleteProgram(glPrograms.get(id));
  glPrograms.delete(id);
};

const glDeleteBuffer = (id) => {
  gl.deleteBuffer(glBuffers.get(id));
  glBuffers.delete(id);
};

const glDeleteBuffers = (number, pointer) => {
  const buffers = new Uint32Array(zjs.memory.buffer, pointer, number);
  for (let n = 0; n < number; n++) {
    gl.deleteBuffer(glBuffers.get(buffers[n]));
    glBuffers.delete(buffers[n]);
  }
};

const glDeleteShader = (id) => {
  console.error("shader deleted");
  gl.deleteShader(glShaders.get(id));
  glShaders.delete(id);
};

const glCreateShader = (type) => {
  const shader = gl.createShader(type);
  const id = getId();
  glShaders.set(id, shader);
  return id;
};

const glCompileShader = (id) => {
  gl.compileShader(glShaders.get(id));
};

// This differs from OpenGL version due to problems with reading strings till
// null termination.
const glShaderSource = (shader, amount, pointer) => {
  const addr = new Uint32Array(zjs.memory.buffer, pointer)[0];
  const str = new Uint8Array(zjs.memory.buffer, addr);
  let i = 0;
  while (str[i] !== 0) i++;
  const source = textDecoder.decode(str.slice(0, i));
  gl.shaderSource(glShaders.get(shader), source);
};

const glCreateProgram = () => {
  const id = getId();
  const program = gl.createProgram();
  glPrograms.set(id, program);
  return id;
};

const glGetShaderiv = (id, parameter, ptr) => {
  const ret = gl.getShaderParameter(glShaders.get(id), parameter);
  const data = new Int32Array(zjs.memory.buffer, ptr, 1);
  data[0] = ret;
};

const glGetProgramiv = (id, parameter, ptr) => {
  const ret = gl.getProgramParameter(glPrograms.get(id), parameter);
  const data = new Int32Array(zjs.memory.buffer, ptr, 1);
  data[0] = ret;
};

const glGetShaderInfoLog = (id, length, lengthPointer, messagePointer) => {
  const message = new Uint8Array(zjs.memory.buffer, messagePointer, length);
  const info = gl.getShaderInfoLog(glShaders.get(id));

  for (let i = 0; i < info.length; i++) {
    message[i] = info.charCodeAt(i);
  }
};

const glGetProgramInfoLog = (id, length, lengthPointer, messagePointer) => {
  const message = new Uint8Array(zjs.memory.buffer, messagePointer, length);
  const info = gl.getProgramInfoLog(glPrograms.get(id));

  for (let i = 0; i < info.length; i++) {
    message[i] = info.charCodeAt(i);
  }
};

const glLinkProgram = (id) => {
  gl.linkProgram(glPrograms.get(id));
};

const glBindBuffer = (type, bufferId) => {
  gl.bindBuffer(type, glBuffers.get(bufferId));
};

const glBufferData = (type, count, pointer, drawType) => {
  // The Float32Array multiplies by size of float which is 4, and the call to
  // this method, due to OpenGL compatibility, also receives already
  // pre-multiplied value.
  gl.bufferData(type, zjs.memory.buffer.slice(pointer, pointer + count), drawType);
};

const glBufferSubData = (target, offset, size, data) => {
  // The Float32Array multiplies by size of float which is 4, and the call to
  // this method, due to OpenGL compatibility, also receives already
  // pre-multiplied value.
  gl.bufferSubData(target, offset, zjs.memory.buffer.slice(data, data + size));
};

const glUseProgram = (programId) => {
  gl.useProgram(glPrograms.get(programId));
};

const glEnableVertexAttribArray = (value) => {
  gl.enableVertexAttribArray(value);
};

const glVertexAttribPointer = (
  attribLocation,
  size,
  type,
  normalize,
  stride,
  offset
) => {
  gl.vertexAttribPointer(attribLocation, size, type, normalize, stride, offset);
};

const glVertexAttribIPointer = (
  attribLocation,
  size,
  type,
  stride,
  offset
) => {
  gl.vertexAttribIPointer(attribLocation, size, type, stride, offset);
};

const glVertexAttribDivisor = (index, divisor) => {
  gl.vertexAttribDivisor(index, divisor);
}

const glGenFramebuffers = (n, ptr) => {
  const buffers = new Uint32Array(zjs.memory.buffer, ptr, n);
  for (let i = 0; i < n; i++) {
    const id = getId();
    const b = gl.createFramebuffer();
    glFrameBuffers.set(id, b);
    buffers[i] = id;
  }
}

const glDeleteFramebuffers = (n, ptr) => {
  const buffers = new Uint32Array(zjs.memory.buffer, ptr, n);
  for (let i = 0; i < n; i++) {
    const b = glFrameBuffers.get(buffers[i]);
    gl.deleteFramebuffer(b);
  }
}

const glBindFramebuffer = (target, fb) => {
  const b = glFrameBuffers.get(fb);
  gl.bindFramebuffer(target, b);
}

const glTexSubImage2D = (target, level, xoffset, yoffset, width, height, format, type, pixels) => {
  let size = 1;
  if (format === gl.RGBA) {
    size = 4;
  } else if (format === gl.RED) {
    size = 1;
  } else if (format == 32993) {
    size = 4;
    format = gl.RGBA
  } else {
    throw new Error("Add pixel count for this format.");
  }

  const data = new Uint8Array(zjs.memory.buffer, pixels, width * height * size);
  gl.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, data)
}
const glGetIntegerv = (pname, ptr) => {
  const data = new Uint32Array(zjs.memory?.buffer, ptr, 1);
  data[0] = gl.getParameter(pname);
}

const glUniform4f = (locationId, x, y, z, w) => {
  gl.uniform4f(glUniformLocations.get(locationId), x, y, z, w);
};
const glDrawElementsInstanced = (mode, count, type, indices, instancecount) => {
  gl.drawElementsInstanced(mode, count, type, indices, instancecount);
};
const glBindBufferBase = (target, index, buffer) => {
  gl.bindBufferBase(target, index, glBuffers.get(buffer))
}
const glDrawArrays = (type, offset, count) => {
  gl.drawArrays(type, offset, count);
};

const glCreateTexture = () => {
  const id = getId();
  glTextures.set(id, gl.createTexture());
  return id;
};

const glGenTextures = (number, pointer) => {
  const textures = new Uint32Array(zjs.memory.buffer, pointer, number);
  for (let n = 0; n < number; n++) {
    const texture = glCreateTexture();
    textures[n] = texture;
  }
};

const glDeleteTextures = (number, pointer) => {
  const textures = new Uint32Array(zjs.memory.buffer, pointer, number);
  for (let n = 0; n < number; n++) {
    gl.deleteTexture(glBuffers[n]);
    glTextures.delete(textures[n]);
  }
};

const glDeleteTexture = (id) => {
  gl.deleteTexture(glTextures.get(id));
  glTextures.delete(id);
};

const glBindTexture = (target, id) => {
  return gl.bindTexture(target, glTextures.get(id));
};

const glTexImage2D = (
  target,
  level,
  internalFormat,
  width,
  height,
  border,
  format,
  type,
  pointer
) => {
  let size = 1;
  if (format === gl.RGBA) {
    size = 4;
  } else if (format == gl.RED) {
    size = 1;
    internalFormat = gl.R8
  } else if (format == 32993) {
    size = 4;
    format = gl.RGBA
  } else {
    throw new Error("Add pixel count for this format.");
  }

  const data = new Uint8Array(zjs.memory.buffer, pointer, width * height * size);

  gl.texImage2D(
    target,
    level,
    internalFormat,
    width,
    height,
    border,
    format,
    type,
    data
  );
};

const glTexParameteri = (target, name, parameter) => {
  gl.texParameteri(target, name, parameter);
};

const glActiveTexture = (target) => {
  return gl.activeTexture(target);
};

const glGenerateMipmap = (value) => {
  gl.generateMipmap(value);
};

const glCreateVertexArray = () => {
  const id = getId();
  glVertexArrays.set(id, gl.createVertexArray());
  return id;
};

const glGenVertexArrays = (number, pointer) => {
  const vaos = new Uint32Array(zjs.memory.buffer, pointer, number);
  for (let n = 0; n < number; n++) {
    const b = glCreateVertexArray();
    vaos[n] = b;
  }
};

const glDeleteVertexArrays = (number, pointer) => {
  const vaos = new Uint32Array(zjs.memory.buffer, pointer, number);
  for (let n = 0; n < number; n++) {
    glVertexArrays.delete(vaos[n]);
  }
};

const glBindVertexArray = (id) => gl.bindVertexArray(glVertexArrays.get(id));

const glPixelStorei = (type, alignment) => gl.pixelStorei(type, alignment);

const glGetError = () => {
  return gl.getError();
}

const webgl = {
  glViewport,
  glClearColor,
  glEnable,
  glDisable,
  glDepthFunc,
  glBlendFunc,
  glClear,
  glGetAttribLocation,
  glGetUniformLocation,
  glUniform4fv,
  glUniform2f,
  glUniform1i,
  glUniform1f,
  glUniformMatrix4fv,
  glCreateVertexArray,
  glGenVertexArrays,
  glDeleteVertexArrays,
  glBindVertexArray,
  glCreateBuffer,
  glGenBuffers,
  glDeleteBuffers,
  glDeleteBuffer,
  glBindBuffer,
  glBufferData,
  glBufferSubData,
  glPixelStorei,
  glAttachShader,
  glDetachShader,
  glDeleteShader,
  glCreateShader,
  glCompileShader,
  glShaderSource,
  glCreateProgram,
  glGetShaderInfoLog,
  glGetProgramInfoLog,
  glLinkProgram,
  glUseProgram,
  glDeleteProgram,
  glEnableVertexAttribArray,
  glVertexAttribPointer,
  glVertexAttribIPointer,
  glDrawArrays,
  glCreateTexture,
  glGenTextures,
  glDeleteTextures,
  glDeleteTexture,
  glBindTexture,
  glTexImage2D,
  glTexParameteri,
  glActiveTexture,
  glGenerateMipmap,
  glGetError,
  glGetShaderiv,
  glGetProgramiv,
  glVertexAttribDivisor,
  glGenFramebuffers,
  glDeleteFramebuffers,
  glBindFramebuffer,
  glTexSubImage2D,
  glGetIntegerv,
  glUniform4f,
  glDrawElementsInstanced,
  glBindBufferBase,
}
const nsToMs = (ns: number | bigint) => {
  if (typeof ns === "number") {
    ns = Math.trunc(ns);
  }
  const nsInt = BigInt(ns);
  return Number(nsInt / BigInt(1000000));
};
const msToNs = (ms: number) => {
  const msInt = Math.trunc(ms);
  const decimal = BigInt(Math.round((ms - msInt) * 1000000));
  const ns = BigInt(msInt) * BigInt(1000000);
  return ns + decimal;
};
const CPUTIME_START = msToNs(perfNow());
const now = (clockId?: number) => {
  switch (clockId) {
    case WASI_CLOCK_MONOTONIC:
      return msToNs(perfNow());
    case WASI_CLOCK_REALTIME:
      return msToNs(Date.now());
    case WASI_CLOCK_PROCESS_CPUTIME_ID:
    case WASI_CLOCK_THREAD_CPUTIME_ID: // TODO -- this assumes 1 thread
      return msToNs(perfNow()) - CPUTIME_START;
    default:
      return null;
  }
};
let files: { polling: SharedArrayBuffer, nextFd: SharedArrayBuffer, has: SharedArrayBuffer };
export function setFiles(file) {
  files = file;
}
const fdStart = 4;

export const importObject = {
  module: {},
  env: {
    memory: new WebAssembly.Memory({
      initial: 512,
      maximum: 65536,
      shared: true,
    }),
    ...webgl,
    log: (ptr: number, len: number) => {
      const arr = new Uint8ClampedArray(zjs.memory.buffer, ptr, len);
      const data = arr.slice();
      const str = textDecoder.decode(data);
      console.error(str);
    },
    eventFd() {
      const next = new Int32Array(files.nextFd);
      return Atomics.add(next, 0, 1);

    },
    fork: (...params) => {
      console.error("fork", params);
    },
    execve: (...params) => {
      console.error("execve", params);
    },
    pipe: (...params) => {
      console.error("pipe", params);
    },
    realpath: (...params) => {
      console.error("realpath", params);
    },
    pthread_mutex_lock: (...params) => {
      console.error("pthread_mutex_lock", params);
    },
    pthread_cond_wait: (...params) => {
      console.error("pthread_cond_wait", params);
    },
    pthread_mutex_unlock: (...params) => {
      console.error("pthread_mutex_unlock", params);
    },
    __cxa_allocate_exception: (...params) => {
      console.error("__cxa_allocate_exception", params);
    },
    pthread_cond_broadcast: (...params) => {
      console.error("pthread_cond_broadcast", params);
    },
    __cxa_throw: (...params) => {
      console.error("__cxa_throw", params);
    },

  },
  wasi_snapshot_preview1: {
    fd_write: (fd, iovs, iovs_len, nwritten_ptr) => {
      if (fd >= fdStart) {
        const memory = new DataView(zjs.memory.buffer);
        let nwritten = 0;
        for (let offset = iovs; offset < iovs + iovs_len * 8; offset += 8) {
          const iov_len = memory.getUint32(offset + 4, true);
          nwritten += iov_len;
        }
        const has = new Int32Array(files.has);
        Atomics.store(has, fd - fdStart, 1);
        Atomics.notify(has, fd - fdStart);
        console.error("notify", fd);
        memory.setUint32(nwritten_ptr, nwritten, true);

      } else {
        const memory = new DataView(zjs.memory.buffer);
        let buf = "";
        let nwritten = 0;
        for (let offset = iovs; offset < iovs + iovs_len * 8; offset += 8) {
          const iov_base = memory.getUint32(offset, true);
          const iov_len = memory.getUint32(offset + 4, true);
          buf += textDecoder.decode(new Uint8ClampedArray(memory.buffer.slice(iov_base, iov_base + iov_len)).slice());
          nwritten += iov_len;
        }
        memory.setUint32(nwritten_ptr, nwritten, true);
        console.error(buf);
      }
    },
    fd_close: (...params) => {
      console.error("fd_close", params);
    },
    fd_fdstat_get: (...params) => {
      console.error("fd_fdstat_get", params);
    },
    fd_fdstat_set_flags: (...params) => {
      console.error("fd_fdstat_set_flags", params);
    },
    fd_filestat_get: (...params) => {
      console.error("fd_filestat_get", params);
    },
    fd_pread: (...params) => {
      console.error("fd_pread", params);
    },
    fd_prestat_get: (...params) => {
      console.error("fd_prestat_get", params);
    },
    fd_prestat_dir_name: (...params) => {
      console.error("fd_prestat_dir_name", params);
    },
    fd_pwrite: (...params) => {
      console.error("fd_pwrite", params);
    },
    fd_read(fd, iovs, iovsLen, nreadPtr) {
      if (fd >= fdStart) {
        const memory = new DataView(zjs.memory.buffer);
        let nwritten = 0;
        for (let offset = iovs; offset < iovs + iovsLen * 8; offset += 8) {
          const iov_base = memory.getUint32(offset, true);
          const iov_len = memory.getUint32(offset + 4, true);
          // new Uint8ClampedArray(memory.buffer.slice(iov_base, iov_base + iov_len)).fill(1);
          nwritten += iov_len;
          memory.setUint32(nreadPtr, nwritten, true);
        }
      } else {
        const memory = new DataView(zjs.memory.buffer);
        let nwritten = 0;
        for (let offset = iovs; offset < iovs + iovsLen * 8; offset += 8) {
          if (bytes == null) readStdin();
          if (bytes == null) break;
          const iov_base = memory.getUint32(offset, true);
          const iov_len = memory.getUint32(offset + 4, true);
          const read = Math.min(iov_len, bytes.length);
          const io = new Uint8ClampedArray(zjs.memory.buffer, iov_base, iov_len);
          io.set(bytes.slice(0, read));
          bytes = bytes.slice(read);
          if (bytes.length === 0) bytes = null;
          nwritten += read;
          if (read !== iov_len) break;
        }

        memory.setUint32(nreadPtr, nwritten, true);
        if (nwritten > 0)
        console.error("fd_read", nwritten);
      }
    },
    fd_seek: (...params) => {
      console.error("fd_seek", params);
    },
    path_filestat_get: (...params) => {
      console.error("path_filestat_get", params);
    },
    path_open: (...params) => {
      console.error("path_open", params);
    },
    path_unlink_file: (...params) => {
      console.error("path_unlink_file", params);
    },
    poll_oneoff(
      sin: number,
      sout: number,
      nsubscriptions: number,
      neventsPtr: number
    ) {
      
      let nevents = 0;
      let name = "";

      // May have to wait this long (this gets computed below in the WASI_EVENTTYPE_CLOCK case).

      let waitTimeNs = BigInt(0);

      let fd = -1;
      let fd_type: "read" | "write" = "read";
      let fd_timeout_ms = 0;

      const startNs = BigInt(msToNs(perfNow()));
      let view = new DataView(zjs.memory.buffer);
      let last_sin = sin;
      for (let i = 0; i < nsubscriptions; i += 1) {
        const userdata = view.getBigUint64(sin, true);
        sin += 8;
        const type = view.getUint8(sin);
        sin += 1;
        sin += 7; // padding
        if (type == WASI_EVENTTYPE_CLOCK) {
          name = "poll_oneoff (type=WASI_EVENTTYPE_CLOCK): ";
        } else if (type == WASI_EVENTTYPE_FD_READ) {
          name = "poll_oneoff (type=WASI_EVENTTYPE_FD_READ): ";
        } else {
          name = "poll_oneoff (type=WASI_EVENTTYPE_FD_WRITE): ";
        }
        console.log(name);
        switch (type) {
          case WASI_EVENTTYPE_CLOCK: {
            // see packages/zig/dist/lib/libc/include/wasm-wasi-musl/wasi/api.h
            // for exactly how these values are encoded.  I carefully looked
            // at that header and **this is definitely right**.  Same with the fd
            // in the other case below.
            const clockid = view.getUint32(sin, true);
            sin += 4;
            sin += 4; // padding
            let timeout = view.getBigUint64(sin, true);
            console.log(timeout);
            sin += 8;
            // const precision = view.getBigUint64(sin, true);
            sin += 8;
            const subclockflags = view.getUint16(sin, true);
            sin += 2;
            sin += 6; // padding

            const absolute = subclockflags === 1;
            console.log(name, { clockid, timeout, absolute });
            if (!absolute) {
              fd_timeout_ms = Number(timeout / BigInt(1000000));
            }

            let e = WASI_ESUCCESS;
            const t = now(clockid);
            // logToFile(t, clockid, timeout, subclockflags, absolute);
            if (t == null) {
              e = WASI_EINVAL;
            } else {
              const end = absolute ? timeout : t + timeout;
              const waitNs = end - t;
              if (waitNs > waitTimeNs) {
                waitTimeNs = waitNs;
              }
            }

            view = new DataView(zjs.memory.buffer);
            view.setBigUint64(sout, userdata, true);
            sout += 8;
            view.setUint16(sout, e, true); // error
            sout += 8; // pad offset 2
            view.setUint8(sout, WASI_EVENTTYPE_CLOCK);
            sout += 8; // pad offset 1
            sout += 8; // padding to 8

            nevents += 1;

            break;
          }
          case WASI_EVENTTYPE_FD_READ:
          case WASI_EVENTTYPE_FD_WRITE: {
            /*
            Look at
             lib/libc/wasi/libc-bottom-half/cloudlibc/src/libc/sys/select/pselect.c
            to see how poll_oneoff is actually used by wasi to implement pselect.
            It's also used in
             lib/libc/wasi/libc-bottom-half/cloudlibc/src/libc/poll/poll.c

            "If none of the selected descriptors are ready for the
            requested operation, the pselect() or select() function shall
            block until at least one of the requested operations becomes
            ready, until the timeout occurs, or until interrupted by a signal."
            Thus what is supposed to happen below is supposed
            to block until the fd is ready to read from or write
            to, etc.

            For now at least if reading from stdin then we block for a short amount
            of time if getStdin defined; otherwise, we at least *pause* for a moment
            (to avoid cpu burn) if this.sleep is available.
            */
            fd = view.getUint32(sin, true);
            fd_type = type == WASI_EVENTTYPE_FD_READ ? "read" : "write";
            sin += 4;
            console.log(name, "fd =", fd);
            sin += 28;
            let notify = true;
            if (fd >= fdStart) {
              const has = new Int32Array(files.has);
              Atomics.wait(has, fd - fdStart, 0, 500);
              if (has[fd - fdStart] == 0) {
                console.warn("not notify");
                notify = false;
              } else {
                console.warn("notify");
                notify = true;
                Atomics.store(has, fd - fdStart, 0)
              }
            }

            if (notify) {
              view = new DataView(zjs.memory.buffer);
              view.setBigUint64(sout, userdata, true);
              sout += 8;
              view.setUint16(sout, WASI_ENOSYS, true); // error
              sout += 8; // pad offset 2
              view.setUint8(sout, type);
              sout += 8; // pad offset 3
              sout += 8; // padding to 8

              nevents += 1;
            }
            /*
            TODO: for now for stdin we are just doing a dumb hack.

            We just do something really naive, which is "pause for a little while".
            It seems to work for every application I have so far, from Python to
            to ncurses, etc.  This also makes it easy to have non-blocking sleep
            in node.js at the terminal without a worker thread, which is very nice!

            Before I had it block here via getStdin when available, but that does not work
            in general; in particular, it breaks ncurses completely. In
               ncurses/tty/tty_update.c
            the following call is assumed not to block, and if it does, then ncurses
            interaction becomes totally broken:

               select(SP_PARM->_checkfd + 1, &fdset, NULL, NULL, &ktimeout)

            */
            if (fd == WASI_STDIN_FILENO && WASI_EVENTTYPE_FD_READ == type) {
              sleep(5000);
            }

            break;
          }
          default:
            return WASI_EINVAL;
        }

        // Consistency check that we consumed exactly the right amount
        // of the __wasi_subscription_t. See zig/lib/libc/include/wasm-wasi-musl/wasi/api.h
        if (sin - last_sin != 48) {
          console.warn("*** BUG in wasi-js in poll_oneoff ", {
            i,
            sin,
            last_sin,
            diff: sin - last_sin,
          });
        }
        last_sin = sin;
      }

      view = new DataView(zjs.memory.buffer);
      view.setUint32(neventsPtr, nevents, true);

      // if (nevents == 2 && fd >= 0) {
      //   const r = this.wasiImport.sock_pollSocket(fd, fd_type, fd_timeout_ms);
      //   if (r != WASI_ENOSYS) {
      //     // special implementation from outside
      //     return r;
      //   }
      //   // fall back to below
      // }

      // Account for the time it took to do everything above, which
      // can be arbitrarily long:
      if (waitTimeNs > 0) {
        waitTimeNs -= msToNs(perfNow()) - startNs;
        // logToFile("waitTimeNs", waitTimeNs);
        if (waitTimeNs >= 1000000) {
          const ms = nsToMs(waitTimeNs);
          sleep(ms);
        }
      }

      return WASI_ESUCCESS;
    },
    proc_exit: (...params) => {
      console.error("proc_exit", params);
    },
    sock_shutdown: (...params) => {
      console.error("sock_shutdown", params);
    },
    sock_accept: (...params) => {
      console.error("sock_accept", params);
    },
    sock_recv: (...params) => {
      console.error("sock_recv", params);
    },
    sock_send: (...params) => {
      console.error("sock_send", params);
    },
    random_get: (ptr, len) => {
      const memory = new Uint8Array(zjs.memory.buffer, ptr, len).slice();
      crypto.getRandomValues(memory);
    },
    environ_get: (...params) => {
      console.error("environ_get", params);
    },
    clock_time_get: (_clock, _precision, ptr) => {
      const data = new DataView(zjs.memory.buffer);
      data.setBigUint64(ptr, msToNs(perfNow()), true)
    },
    environ_sizes_get: (...params) => {
      console.error("environ_sizes_get", params);
    },
  },
  wasi: {
    "thread-spawn": (instance) => {
      if (mainThread) {
        spawnWorker(instance)
      } else {
        postMessage([instance])
      }

    }
  },

  ...zjs.importObject(),
};
function spawnWorker(instance) {
  const worker = new Worker(new URL("worker.ts", import.meta.url), { type: "module" });
  worker.postMessage([zjs.memory, instance, stdin, wasmModule, files]);
  worker.onmessage = (event) => {
    const [instance] = event.data;
    spawnWorker(instance);
  }
}
