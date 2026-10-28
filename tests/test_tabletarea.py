"""Checks for the pure parts of bin/tabletarea.py. Run: python3 -m unittest discover tests"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin"))
import tabletarea  # noqa: E402

PTH650 = (223.52, 139.7)  # Intuos5 touch M, mm


def window(w, h, x=0, y=0):
    return {"at": [x, y], "size": [w, h]}


class Target(unittest.TestCase):
    def check(self, win, size=PTH650):
        x, y, w, h, aw, ah, ax, ay = tabletarea.AreaLock.target(win, size)
        # The pen has to move the same distance on screen per mm in both directions,
        # which is what keeps a drawn circle round.
        self.assertAlmostEqual(w / aw, h / ah, delta=0.02 * w / aw)
        # The area stays on the tablet.
        self.assertGreaterEqual(ax, 0)
        self.assertGreaterEqual(ay, 0)
        self.assertLessEqual(ax + aw, size[0] + 0.01)
        self.assertLessEqual(ay + ah, size[1] + 0.01)
        return aw, ah, ax, ay

    def test_wider_window_uses_full_width(self):
        # PhotoCraft's tiled window on the test machine: 2536x1416, aspect 1.79 against 1.60.
        aw, ah, ax, ay = self.check(window(2536, 1416, 5132, 12))
        self.assertEqual(aw, PTH650[0])
        self.assertAlmostEqual(ah, 124.8, delta=0.1)
        self.assertAlmostEqual(ay, 7.45, delta=0.05)

    def test_taller_window_uses_full_height(self):
        aw, ah, ax, ay = self.check(window(1000, 1400))
        self.assertEqual(ah, PTH650[1])
        self.assertLess(aw, PTH650[0])
        self.assertGreater(ax, 0)

    def test_same_aspect_uses_whole_tablet(self):
        aw, ah, ax, ay = self.check(window(1600, 1000))
        self.assertAlmostEqual(aw, PTH650[0], delta=0.1)
        self.assertAlmostEqual(ah, PTH650[1], delta=0.1)

    def test_empty_window_is_refused(self):
        self.assertIsNone(tabletarea.AreaLock.target(window(0, 100), PTH650))


if __name__ == "__main__":
    unittest.main()
