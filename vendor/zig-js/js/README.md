# zig-js Glue

This is the JS library that glues with the Zig library so that Zig
can communicate with the host JS environment when compiled to WebAssembly.
Learn more about the zig-js library at the
[zig-js repository](https://github.com/mitchellh/zig-js).

## Installation

There are two methods for using the JS side of zig-js:

1. This library is a standard npm package, so you can install and use it
   as you normally would any other package. Add it to your package.json and
   integrate it with the bundler you're already using.

2. You can run `npm run build` in this directory and the library will be
   bundled into a single JS file in `dist/`. You can then copy the single JS
   file into your web project. We bundle both a normal CJS
   module at `dist/index.js` as well as an ES module at `dist/module.js`.
   TypeScript type definitions are available in `dist/types.d.ts`.

