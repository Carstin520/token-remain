export const LIMITS_VISIBILITY_KEY = "tokenremain.windows.limitsVisibility.v1";

function uniqueKnown(values, availableSet) {
  const result = [];
  for (const value of Array.isArray(values) ? values : []) {
    if (availableSet.has(value) && !result.includes(value)) result.push(value);
  }
  return result;
}

/// Limits visibility is explicit user state, while newly discovered providers
/// still appear automatically until the user removes them. This mirrors the
/// Mac contract without pretending Windows can collect every provider itself.
export function normalizeLimitsVisibility(raw, availableIDs = [], discoveredIDs = []) {
  const available = [...new Set(availableIDs)];
  const availableSet = new Set(available);
  const hidden = uniqueKnown(raw?.hidden, availableSet);
  const hiddenSet = new Set(hidden);
  const visible = uniqueKnown(raw?.visible, availableSet).filter((id) => !hiddenSet.has(id));
  for (const id of discoveredIDs) {
    if (availableSet.has(id) && !hiddenSet.has(id) && !visible.includes(id)) visible.push(id);
  }
  if (!visible.length && available.length) {
    const fallback = available.find((id) => !hiddenSet.has(id)) || available[0];
    visible.push(fallback);
    const index = hidden.indexOf(fallback);
    if (index >= 0) hidden.splice(index, 1);
  }
  return { version: 1, visible, hidden };
}

export function setProviderVisible(layout, providerID, visible, availableIDs, discoveredIDs) {
  const normalized = normalizeLimitsVisibility(layout, availableIDs, discoveredIDs);
  if (visible) {
    return normalizeLimitsVisibility({
      visible: [...normalized.visible, providerID],
      hidden: normalized.hidden.filter((id) => id !== providerID),
    }, availableIDs, discoveredIDs);
  }
  if (normalized.visible.length <= 1 || !normalized.visible.includes(providerID)) return normalized;
  return normalizeLimitsVisibility({
    visible: normalized.visible.filter((id) => id !== providerID),
    hidden: [...normalized.hidden, providerID],
  }, availableIDs, discoveredIDs.filter((id) => id !== providerID));
}

export function readLimitsVisibility(storage, key, availableIDs, discoveredIDs) {
  if (!storage) return normalizeLimitsVisibility(undefined, availableIDs, discoveredIDs);
  try {
    return normalizeLimitsVisibility(JSON.parse(storage.getItem(key) || "null"), availableIDs, discoveredIDs);
  } catch {
    return normalizeLimitsVisibility(undefined, availableIDs, discoveredIDs);
  }
}

export function writeLimitsVisibility(storage, key, layout) {
  if (!storage) return;
  storage.setItem(key, JSON.stringify({ version: 1, visible: layout.visible, hidden: layout.hidden }));
}
