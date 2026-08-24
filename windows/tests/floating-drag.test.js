import assert from "node:assert/strict";
import test from "node:test";
import { applyDragDelta } from "../electron/floating-drag.js";

const PRIMARY = { x: 0, y: 0, width: 1920, height: 1032 };
const START = { x: 120, y: 80, width: 80, height: 80 };

test("Floating drag applies a screen-space DIP delta to the start bounds", () => {
  assert.deepEqual(applyDragDelta(START, { dx: 240, dy: 135 }, [PRIMARY]), {
    x: 360, y: 215, width: 80, height: 80,
  });
});

test("Floating drag clamps every edge to the display work area", () => {
  assert.deepEqual(applyDragDelta(START, { dx: -500, dy: -500 }, [PRIMARY]), {
    x: 0, y: 0, width: 80, height: 80,
  });
  assert.deepEqual(applyDragDelta(START, { dx: 5_000, dy: 5_000 }, [PRIMARY]), {
    x: 1840, y: 952, width: 80, height: 80,
  });
});

test("Floating drag accepts a widget spanning adjacent display work areas", () => {
  const displays = [
    PRIMARY,
    { x: 1920, y: 0, width: 2560, height: 1392 },
  ];
  const seamStart = { x: 1800, y: 120, width: 80, height: 80 };
  assert.deepEqual(applyDragDelta(seamStart, { dx: 80, dy: 0 }, displays), {
    x: 1880, y: 120, width: 80, height: 80,
  });
  assert.deepEqual(applyDragDelta(seamStart, { dx: 400, dy: 0 }, displays), {
    x: 2200, y: 120, width: 80, height: 80,
  });
});

test("Floating drag rejects non-finite and absurd deltas", () => {
  assert.equal(applyDragDelta(START, { dx: Number.NaN, dy: 0 }, [PRIMARY]), undefined);
  assert.equal(applyDragDelta(START, { dx: 0, dy: Number.POSITIVE_INFINITY }, [PRIMARY]), undefined);
  assert.equal(applyDragDelta(START, { dx: 10_001, dy: 0 }, [PRIMARY]), undefined);
  assert.equal(applyDragDelta(START, { dx: 0, dy: -10_001 }, [PRIMARY]), undefined);
});
