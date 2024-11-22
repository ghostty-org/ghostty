import { ZigJS } from "zig-js/src/index.ts";

const textDecoder = new TextDecoder("utf-8");

let gl: WebGL2RenderingContext;
export function setGl(l) {
  gl = l;
}

export const zjs = new ZigJS();
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
} catch (e){console.error(e) }

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
  gl.bufferData(type, zjs.memory.buffer.slice(pointer, pointer+count), drawType);
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
    fd_read: (...params) => {
      console.error("fd_read", params);
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
    poll_oneoff: (...params) => {
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
      data.setBigUint64(ptr, BigInt(Date.now()) * 1000000n, true)
    },
    environ_sizes_get: (...params) => {
      console.error("environ_sizes_get", params);
    },
  },
  wasi: {
    "thread-spawn": (instance) => {
      const worker = new Worker(new URL("worker.ts", import.meta.url), { type: "module" });
      worker.postMessage([zjs.memory, instance]);

    }
  },

  ...zjs.importObject(),
};
