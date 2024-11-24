Performance:

- Loading fonts on startups should probably happen in multiple threads

Correctness:

- test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way
- Charsets: UTF-8 vs. ASCII mode
  - we only support UTF-8 input right now
  - need fallback glyphs if they're not supported
  - can effect a crash using `vttest` menu `3 10` since it tries to parse
    ASCII as UTF-8.

Mac:

- Preferences window

Major Features:

- Bell
