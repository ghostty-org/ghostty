# HLSL Shaders

Pre-compiled shader bytecode for the DirectX 11 renderer.

## Recompiling

Requires the Windows SDK (`fxc.exe`):

```
fxc /T vs_5_0 /E VSMain /Fo cell_vs.cso cell.hlsl
fxc /T ps_5_0 /E PSMain /Fo cell_ps.cso cell.hlsl
```

The `.cso` files are embedded at comptime via `@embedFile` in `pipeline.zig`.
