import assert from "node:assert/strict";
import test from "node:test";
import { DASHBOARD_SECTIONS, parseLaunchArgs } from "../electron/launch-args.js";

test("Launch arguments open the dashboard and allow-listed sections", () => {
  assert.deepEqual(parseLaunchArgs(["TokenRemain.exe", "--open-dashboard"]), {
    target: "dashboard",
    dashboardSection: undefined,
    openPopupSettings: false,
    resetOnboarding: false,
  });
  for (const section of DASHBOARD_SECTIONS) {
    assert.deepEqual(parseLaunchArgs(["--open-section", section]), {
      target: "dashboard",
      dashboardSection: section,
      openPopupSettings: false,
      resetOnboarding: false,
    });
  }
});

test("Launch arguments reject missing and unknown dashboard sections", () => {
  assert.equal(parseLaunchArgs(["--open-section"]).dashboardSection, undefined);
  assert.equal(parseLaunchArgs(["--open-section", "billing"]).dashboardSection, undefined);
  assert.equal(parseLaunchArgs(["--open-section", "--open-popover"]).target, "popover");
});

test("Popup settings implies a popover and dashboard requests keep precedence", () => {
  assert.deepEqual(parseLaunchArgs(["--open-popup-settings", "--reset-onboarding"]), {
    target: "popover",
    dashboardSection: undefined,
    openPopupSettings: true,
    resetOnboarding: true,
  });
  assert.equal(parseLaunchArgs(["--open-popover", "--open-dashboard"]).target, "dashboard");
  assert.equal(parseLaunchArgs(["--open-popover", "--open-section", "limits"]).dashboardSection, "limits");
});

test("Unknown flags and executable paths are ignored", () => {
  assert.deepEqual(parseLaunchArgs(["C:\\Program Files\\TokenRemain\\TokenRemain.exe", "--future-flag", "value"]), {
    target: "dashboard",
    dashboardSection: undefined,
    openPopupSettings: false,
    resetOnboarding: false,
  });
});
