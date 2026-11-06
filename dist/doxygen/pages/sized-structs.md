# Sized Structs {#sized-structs}

Struct size, layout, and alignment is part of the C ABI. We want to
have the ability to add fields to structs without breaking existing programs.
To achieve this, we use a common pattern known as "sized structs." Sized
structs are mildly annoying so we do our best to limit this as much as possible.

A sized struct starts with a `size_t size` field. It tells us how big the struct
was when you compiled, and we only touch that much memory. New fields always
go at the end. That way, we never write beyond the amount of memory you allocate.

In C you never set `size` by hand. Use GHOSTTY_INIT_SIZED():

```c
GhosttyTerminalSelectLineOptions opts =
    GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
opts.ref = ref;

GhosttySelection selection;
GhosttyResult result =
    ghostty_terminal_select_line(terminal, &opts, &selection);
```

It sets `size` for you and sets every other field to zero. Then you fill in the
fields you need. Language bindings that can't use a C macro can call
ghostty_sized_init() instead.

Zero is always the default value of a field. A field you leave at zero behaves
the way the library did before that field existed. This is why
GHOSTTY_INIT_SIZED() matters. It keeps every field you didn't set at its
default, including fields added in later releases.

## Newer Headers, Older Libraries {#sized-structs-older-libraries}

Your program and the library it loads may come from different releases. The
`size` field lets the library handle either case:

- When you pass a struct to the library, such as an options struct or a
  clipboard reply, and the library is newer than your header, the library reads
  the fields your struct doesn't have as zero.
- When the library is older than your header, it accepts your struct as long as
  every field it doesn't know about is still zero. If you set one of those
  fields, the call returns GHOSTTY_INVALID_VALUE. We won't silently ignore a
  setting we can't honor.
- When the library fills a struct for you, such as GhosttyRenderStateCursor, it
  writes only the fields that fit within `size`. Fields the library doesn't know
  about keep the value you gave them, which is zero if you used
  GHOSTTY_INIT_SIZED().

In every case, a `size` smaller than the struct has ever been returns
GHOSTTY_INVALID_VALUE. Clipboard replies are the one exception. The reply
function has no return value, so a reply with an invalid `size` is treated as
unsupported instead.

Here is how you can use a newer field when the library supports it and fall back
when it doesn't. Imagine that `semantic_prompt_boundary` was added in a later
release than the library your program loads:

```c
GhosttyTerminalSelectLineOptions opts =
    GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
opts.ref = ref;
opts.semantic_prompt_boundary = true;

GhosttySelection selection;
GhosttyResult result =
    ghostty_terminal_select_line(terminal, &opts, &selection);
if (result == GHOSTTY_INVALID_VALUE) {
  // This library may predate semantic_prompt_boundary. Try again
  // without it.
  opts.semantic_prompt_boundary = false;
  result = ghostty_terminal_select_line(terminal, &opts, &selection);
}
```
