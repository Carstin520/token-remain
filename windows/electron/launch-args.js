export const DASHBOARD_SECTIONS = new Set(["overview", "limits", "trends", "devices", "dataSources", "settings"]);

/// Pure launch grammar shared by first launch and Electron's second-instance
/// callback. Unknown flags are inert; a malformed section never escapes the
/// same allow-list used by dashboard IPC navigation.
export function parseLaunchArgs(argv = []) {
  let dashboardSection;
  let openDashboard = false;
  let openPopover = false;
  let openPopupSettings = false;
  let resetOnboarding = false;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--open-section") {
      const candidate = argv[index + 1];
      if (typeof candidate === "string" && !candidate.startsWith("--")) {
        if (!dashboardSection && DASHBOARD_SECTIONS.has(candidate)) dashboardSection = candidate;
        index += 1;
      }
    } else if (argument === "--open-dashboard") {
      openDashboard = true;
    } else if (argument === "--open-popover") {
      openPopover = true;
    } else if (argument === "--reset-onboarding") {
      resetOnboarding = true;
    } else if (argument === "--open-popup-settings") {
      openPopupSettings = true;
      openPopover = true;
    }
  }

  const target = dashboardSection || openDashboard ? "dashboard" : openPopover ? "popover" : "dashboard";
  return {
    target,
    dashboardSection,
    openPopupSettings,
    resetOnboarding,
  };
}
