//go:build !khostty_custom_lib

package khostty

// Default link configuration: the prebuilt libghostty-vt that lives in the
// Khostty checkout this module sits inside. It is valid only for a normal
// in-tree checkout, which is why it is paired with an opt-out build tag.
//
// ${SRCDIR} is expanded by the go tool to the absolute directory holding
// this file, so the flags below resolve to <checkout>/include and
// <checkout>/zig-out/lib. On Windows, tools/windows-env.ps1 sets up the
// compiler and runtime DLL search path for the current PowerShell session.
// Zig's Windows linker resolves -lghostty-vt to ghostty-vt.lib (the DLL
// import library), distinct from the standalone ghostty-vt-static.lib.
//
// The rpath entry is what makes a built test binary or example start: the
// macOS shared object records `@rpath/libghostty-vt.dylib` as its install
// name, so the loader has to be told where that rpath points.
//
// Build the library with:
//
//	zig build -Demit-lib-vt -Doptimize=ReleaseFast
//
// To link against a library elsewhere, build with `-tags khostty_custom_lib`
// and supply CGO_LDFLAGS. See doc.go.

/*
#cgo CFLAGS: -I${SRCDIR}/../include
#cgo LDFLAGS: -L${SRCDIR}/../zig-out/lib -lghostty-vt
#cgo darwin LDFLAGS: -Wl,-rpath,${SRCDIR}/../zig-out/lib
#cgo linux LDFLAGS: -Wl,-rpath,${SRCDIR}/../zig-out/lib
*/
import "C"
