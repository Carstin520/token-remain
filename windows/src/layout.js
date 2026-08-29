export const LIMITS_ORDER_KEY = "tokenremain.windows.limitsOrder.v1";

export function normalizeOrder(order, availableIDs) {
  const available = [...new Set(availableIDs)];
  const availableSet = new Set(available);
  const normalized = [];
  for (const id of Array.isArray(order) ? order : []) {
    if (availableSet.has(id) && !normalized.includes(id)) normalized.push(id);
  }
  for (const id of available) {
    if (!normalized.includes(id)) normalized.push(id);
  }
  return normalized;
}

export function moveItem(order, activeID, destinationID) {
  if (activeID === destinationID) return [...order];
  const sourceIndex = order.indexOf(activeID);
  const destinationIndex = order.indexOf(destinationID);
  if (sourceIndex < 0 || destinationIndex < 0) return [...order];
  const next = [...order];
  const [item] = next.splice(sourceIndex, 1);
  next.splice(destinationIndex, 0, item);
  return next;
}

/// The raw persisted order, or undefined when this PC has none yet. Surfaces
/// come here to tell "the user arranged these cards" apart from "no preference
/// recorded", which they answer with their own default ranking.
export function peekStoredOrder(storage, key) {
  if (!storage) return undefined;
  try {
    const decoded = JSON.parse(storage.getItem(key) || "null");
    return Array.isArray(decoded?.order) ? decoded.order : undefined;
  } catch {
    return undefined;
  }
}

export function readStoredOrder(storage, key, availableIDs) {
  return normalizeOrder(peekStoredOrder(storage, key), availableIDs);
}

export function writeStoredOrder(storage, key, order) {
  if (!storage) return;
  storage.setItem(key, JSON.stringify({ version: 1, order }));
}
