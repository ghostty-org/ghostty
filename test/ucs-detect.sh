#!/bin/sh

# This runs ucs-detect with the same settings consistently so we can
# compare our results over time. This is based on:
# https://github.com/jquast/ucs-detect/blob/2958b7766783c92b3aad6a55e1e752cbe07ccaf3/data/ghostty.yaml
ucs-detect \
  --limit-codepoints=5000 \
  --limit-words=5000 \
  --limit-errors=1000 \
  --stream=stderr
