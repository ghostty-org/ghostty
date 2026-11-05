"""Check actual old/new VT snapshots before declaring a compatible revision."""
import ctypes as c
import os
import unittest


class VT:
    def __init__(self, path):
        self.lib = c.CDLL(path)
        signatures = {
            "ghostty_terminal_new": ([c.c_void_p, c.POINTER(c.c_void_p), c.c_uint16, c.c_uint16], c.c_int),
            "ghostty_terminal_free": ([c.c_void_p], None),
            "ghostty_terminal_set": ([c.c_void_p, c.c_int, c.c_void_p], c.c_int),
            "ghostty_terminal_vt_write": ([c.c_void_p, c.c_void_p, c.c_size_t], None),
            "ghostty_snapshot_encode_alloc": (
                [c.c_void_p, c.c_void_p, c.POINTER(c.c_void_p), c.POINTER(c.c_size_t)], c.c_int),
            "ghostty_snapshot_decoder_new_buf": (
                [c.c_void_p, c.POINTER(c.c_void_p), c.c_void_p, c.c_size_t], c.c_int),
            "ghostty_snapshot_decoder_set": ([c.c_void_p, c.c_int, c.c_void_p], c.c_int),
            "ghostty_snapshot_decoder_decode": ([c.c_void_p, c.POINTER(c.c_void_p)], c.c_int),
            "ghostty_snapshot_decoder_free": ([c.c_void_p], None),
            "ghostty_free": ([c.c_void_p, c.c_void_p, c.c_size_t], None),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = arguments, result

    @staticmethod
    def check(result):
        if result != 0:
            raise AssertionError(f"VT operation failed: {result}")

    def snapshot(self, data, *, restore=None):
        terminal = c.c_void_p()
        if restore is None:
            self.check(self.lib.ghostty_terminal_new(None, c.byref(terminal), 80, 24))
            limit = c.c_size_t(1024 * 1024)
            self.check(self.lib.ghostty_terminal_set(terminal, 31, c.byref(limit)))
        else:
            decoder = c.c_void_p()
            buffer = c.create_string_buffer(restore)
            self.check(self.lib.ghostty_snapshot_decoder_new_buf(
                None, c.byref(decoder), buffer, len(restore)))
            try:
                retain = c.c_bool(True)
                self.check(self.lib.ghostty_snapshot_decoder_set(decoder, 1, c.byref(retain)))
                self.check(self.lib.ghostty_snapshot_decoder_decode(decoder, c.byref(terminal)))
            finally:
                self.lib.ghostty_snapshot_decoder_free(decoder)
        try:
            self.lib.ghostty_terminal_vt_write(terminal, c.create_string_buffer(data), len(data))
            output, size = c.c_void_p(), c.c_size_t()
            self.check(self.lib.ghostty_snapshot_encode_alloc(
                terminal, None, c.byref(output), c.byref(size)))
            try:
                return c.string_at(output, size.value)
            finally:
                self.lib.ghostty_free(None, output, size)
        finally:
            self.lib.ghostty_terminal_free(terminal)


@unittest.skipUnless(os.getenv("OMG_LEGACY_VT_LIBRARY") and os.getenv("OMG_CURRENT_VT_LIBRARY"),
                     "requires previous and current native VT libraries")
class SnapshotCompatibilityTests(unittest.TestCase):
    def test_old_and_new_snapshots_restore_in_both_directions(self):
        old = VT(os.environ["OMG_LEGACY_VT_LIBRARY"])
        new = VT(os.environ["OMG_CURRENT_VT_LIBRARY"])
        samples = [
            (b"plain\r\ntext", b"\r\nnext"),
            (b"\x1b[31mred\x1b[0m \xe4\xb8\xad\xe6\x96\x87", b" next"),
            (b"\x1b[?1049halternate\x1b[3;5Hposition", b"\x1b[?1049lmain"),
            (b"\x1b]7501;state=working:app=codex\x07visible", b" next"),
            (b"before\x1b]7501;state=working:app=co", b"dex\x07after"),
            (b"before\x1b]3008;start=omg-agent-omp-42;type=app;omg_sta",
             b"te=working\x07after"),
            (b"wide\xe4\xb8", b"\xad after"),
            (b"\x1b[38;2;20;", b"40;60mcolor"),
        ]
        for index, (prefix, suffix) in enumerate(samples):
            with self.subTest(sample=index):
                previous, current = old.snapshot(prefix), new.snapshot(prefix)
                self.assertEqual(previous, current)
                self.assertEqual(old.snapshot(suffix, restore=current),
                                 new.snapshot(suffix, restore=previous))


if __name__ == "__main__":
    unittest.main()
