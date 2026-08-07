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

export function readStoredOrder(storage, key, availableIDs) {
  if (!storage) return normalizeOrder([], availableIDs);
  try {
    const decoded = JSON.parse(storage.getItem(key) || "null");
    return normalizeOrder(decoded?.order, availableIDs);
  } catch {
    return normalizeOrder([], availableIDs);
  }
}

export function writeStoredOrder(storage, key, order) {
  if (!storage) return;
  storage.setItem(key, JSON.stringify({ version: 1, order }));
}
