import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { moveItem, normalizeOrder, readStoredOrder, writeStoredOrder } from "./layout.js";

const ACTIVATION_DELAY_MS = 180;
const MOUSE_DRAG_THRESHOLD_PX = 6;
const PRE_ACTIVATION_TOLERANCE_PX = 36;
const OUTSIDE_CANCEL_MARGIN_PX = 48;

export function usePersistentOrder(availableIDs, storageKey) {
  const signature = availableIDs.join("\u0000");
  const [order, setOrder] = useState(() => readStoredOrder(globalThis.localStorage, storageKey, availableIDs));

  useEffect(() => {
    setOrder((current) => normalizeOrder(current, availableIDs));
  }, [signature]);

  useEffect(() => {
    writeStoredOrder(globalThis.localStorage, storageKey, order);
  }, [order, storageKey]);

  return [order, setOrder];
}

export function DirectReorderGrid({ className, order, onOrderChange, renderItem }) {
  const [activeID, setActiveID] = useState();
  const gridRef = useRef(null);
  const itemRefs = useRef(new Map());
  const orderRef = useRef(order);
  const sessionRef = useRef();
  const suppressClickUntilRef = useRef(0);

  useEffect(() => {
    orderRef.current = order;
  }, [order]);

  useLayoutEffect(() => {
    if (activeID && sessionRef.current?.activated) updateDraggedPosition();
  }, [activeID, order]);

  useEffect(() => {
    const endPointer = (event) => finishPointer(event);
    const cancelPointer = (event) => finishPointer(event, true);
    const cancelOnBlur = () => finishPointer(undefined, true);
    globalThis.addEventListener("pointerup", endPointer, true);
    globalThis.addEventListener("pointercancel", cancelPointer, true);
    globalThis.addEventListener("blur", cancelOnBlur);
    return () => {
      clearSessionTimer();
      globalThis.removeEventListener("pointerup", endPointer, true);
      globalThis.removeEventListener("pointercancel", cancelPointer, true);
      globalThis.removeEventListener("blur", cancelOnBlur);
    };
  }, []);

  function clearSessionTimer() {
    const session = sessionRef.current;
    if (session?.timer) globalThis.clearTimeout(session.timer);
    if (session) session.timer = undefined;
  }

  function setItemRef(id, element) {
    if (element) itemRefs.current.set(id, element);
    else itemRefs.current.delete(id);
  }

  function beginPointer(event, id) {
    if (event.button !== 0 || event.target.closest("button, input, select, textarea, a")) return;
    const element = itemRefs.current.get(id);
    if (!element) return;
    clearSessionTimer();
    const rect = element.getBoundingClientRect();
    const session = {
      id,
      pointerID: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      lastX: event.clientX,
      lastY: event.clientY,
      grabOffsetX: event.clientX - rect.left,
      grabOffsetY: event.clientY - rect.top,
      dx: 0,
      dy: 0,
      activated: false,
      pointerType: event.pointerType,
      originalOrder: [...orderRef.current],
    };
    sessionRef.current = session;
    try { element.setPointerCapture(event.pointerId); } catch { /* Pointer may already be gone. */ }
    if (event.pointerType !== "mouse") {
      session.timer = globalThis.setTimeout(() => activateSession(session), ACTIVATION_DELAY_MS);
    }
  }

  function activateSession(session) {
    if (sessionRef.current !== session || session.activated) return;
    clearSessionTimer();
    session.activated = true;
    setActiveID(session.id);
    updateDraggedPosition();
  }

  function movePointer(event) {
    const session = sessionRef.current;
    if (!session || event.pointerId !== session.pointerID) return;
    session.lastX = event.clientX;
    session.lastY = event.clientY;
    if (!session.activated) {
      const distance = Math.hypot(event.clientX - session.startX, event.clientY - session.startY);
      if (session.pointerType === "mouse" && distance >= MOUSE_DRAG_THRESHOLD_PX) {
        activateSession(session);
      } else {
        if (distance > PRE_ACTIVATION_TOLERANCE_PX) finishPointer(event, true);
        return;
      }
    }
    event.preventDefault();
    const bounds = gridRef.current?.getBoundingClientRect();
    if (bounds && (
      event.clientX < bounds.left - OUTSIDE_CANCEL_MARGIN_PX
      || event.clientX > bounds.right + OUTSIDE_CANCEL_MARGIN_PX
      || event.clientY < bounds.top - OUTSIDE_CANCEL_MARGIN_PX
      || event.clientY > bounds.bottom + OUTSIDE_CANCEL_MARGIN_PX
    )) {
      finishPointer(event, true);
      return;
    }
    updateDraggedPosition();
    updateDestination();
  }

  function updateDraggedPosition() {
    const session = sessionRef.current;
    const element = session && itemRefs.current.get(session.id);
    if (!session?.activated || !element) return;
    const rect = element.getBoundingClientRect();
    const baseLeft = rect.left - session.dx;
    const baseTop = rect.top - session.dy;
    session.dx = session.lastX - session.grabOffsetX - baseLeft;
    session.dy = session.lastY - session.grabOffsetY - baseTop;
    element.style.transform = `translate3d(${session.dx}px, ${session.dy}px, 0)`;
  }

  function updateDestination() {
    const session = sessionRef.current;
    if (!session?.activated) return;
    let nearestID = session.id;
    let nearestDistance = Number.POSITIVE_INFINITY;
    for (const id of orderRef.current) {
      const element = itemRefs.current.get(id);
      if (!element) continue;
      const rect = element.getBoundingClientRect();
      const baseLeft = rect.left - (id === session.id ? session.dx : 0);
      const baseTop = rect.top - (id === session.id ? session.dy : 0);
      const distance = Math.hypot(
        session.lastX - (baseLeft + rect.width / 2),
        session.lastY - (baseTop + rect.height / 2),
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestID = id;
      }
    }
    if (nearestID === session.id) return;
    const next = moveItem(orderRef.current, session.id, nearestID);
    orderRef.current = next;
    onOrderChange(next);
  }

  function finishPointer(event, cancelled = false) {
    const session = sessionRef.current;
    if (!session || (event && event.pointerId !== session.pointerID)) return;
    clearSessionTimer();
    sessionRef.current = undefined;
    const element = itemRefs.current.get(session.id);
    if (element) {
      element.style.transform = "";
      try { element.releasePointerCapture(session.pointerID); } catch { /* Capture can already be released. */ }
    }
    if (session.activated) {
      if (cancelled) {
        orderRef.current = session.originalOrder;
        onOrderChange(session.originalOrder);
      }
      suppressClickUntilRef.current = performance.now() + 400;
    }
    setActiveID(undefined);
  }

  function keyboardMove(event, id) {
    if (!event.altKey || !["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
    const index = orderRef.current.indexOf(id);
    const backwards = event.key === "ArrowLeft" || event.key === "ArrowUp";
    const destinationIndex = index + (backwards ? -1 : 1);
    if (index < 0 || destinationIndex < 0 || destinationIndex >= orderRef.current.length) return;
    event.preventDefault();
    const next = moveItem(orderRef.current, id, orderRef.current[destinationIndex]);
    orderRef.current = next;
    onOrderChange(next);
  }

  return (
    <div className={className} ref={gridRef} data-reorder-active={activeID ? "true" : "false"}>
      {order.map((id, index) => (
        <div
          className={`sortable-card ${activeID === id ? "is-dragging" : ""}`}
          data-sortable-id={id}
          key={id}
          ref={(element) => setItemRef(id, element)}
          role="group"
          aria-label={`Component ${index + 1} of ${order.length}. Drag with a mouse or hold and drag on touch to move; Alt plus arrow keys also moves it.`}
          aria-grabbed={activeID === id}
          tabIndex={0}
          onPointerDown={(event) => beginPointer(event, id)}
          onPointerMove={movePointer}
          onPointerUp={(event) => finishPointer(event)}
          onPointerCancel={(event) => finishPointer(event, true)}
          onKeyDown={(event) => keyboardMove(event, id)}
          onClickCapture={(event) => {
            if (performance.now() < suppressClickUntilRef.current) {
              event.preventDefault();
              event.stopPropagation();
            }
          }}
        >
          {renderItem(id)}
        </div>
      ))}
    </div>
  );
}
