# Bidi conformance test data

The tests in `../conformance_test.zig` run against the Unicode Character
Database's own bidi test suites. Those two files total roughly 15 MB, which
is a large thing to add to the repository, so they are **not** checked in
and this directory ignores them.

Download them before running the conformance tests:

```sh
curl -o src/bidi/testdata/BidiTest.txt \
  https://www.unicode.org/Public/UCD/latest/ucd/BidiTest.txt
curl -o src/bidi/testdata/BidiCharacterTest.txt \
  https://www.unicode.org/Public/UCD/latest/ucd/BidiCharacterTest.txt

zig build test -Dtest-filter="bidi conformance"
```

Without them the conformance tests skip with a warning. Everything else in
`src/bidi` is covered by hand-written tests that always run.

## Version

The files must come from the same Unicode version that the property tables
in `src/unicode` were generated from, which is whatever `uucode` vendors
(Unicode 17.0.0 at the time of writing). Mixing versions produces failures
that look like algorithm bugs but are really data mismatches. The version
is in the first line of each file.

## Coverage

The two suites are complementary and both are needed:

- `BidiTest.txt` specifies inputs as Bidi_Class names, so a conforming
  implementation picks a representative character per class. It covers the
  rule combinations exhaustively but cannot express paired brackets,
  because bracket-ness is a property of specific characters rather than of
  a class.
- `BidiCharacterTest.txt` specifies real codepoints, and is what actually
  exercises rule N0. Disabling bracket resolution fails ~14,500 cases here
  and zero in `BidiTest.txt`.
