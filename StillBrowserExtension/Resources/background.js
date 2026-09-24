import { isMeetingBoundary, meetingSignal } from "./sites.js";

const meetings = new Map();
const audibleTabs = new Set();

function forward(signal) {
  browser.runtime.sendNativeMessage("application.id", signal);
}

browser.runtime.onMessage.addListener((message, sender) => {
  const signal = meetingSignal(message);
  if (!signal) {
    return;
  }
  forward(signal);
  const tabID = sender.tab?.id;
  if (tabID !== undefined && isMeetingBoundary(signal.phase)) {
    if (signal.phase === "started") {
      meetings.set(tabID, { host: signal.host, meetingID: signal.meetingID });
    } else {
      meetings.delete(tabID);
      audibleTabs.clear();
    }
  }
});

browser.tabs.onUpdated.addListener((tabID, change) => {
  if (!("audible" in change)) {
    return;
  }
  const [meetingTab, meeting] = [...meetings.entries()][0] ?? [];
  if (!meeting || tabID === meetingTab) {
    return;
  }
  const wasAudible = audibleTabs.size > 0;
  if (change.audible) {
    audibleTabs.add(tabID);
  } else {
    audibleTabs.delete(tabID);
  }
  const isAudible = audibleTabs.size > 0;
  if (wasAudible !== isAudible) {
    forward({ ...meeting, phase: isAudible ? "mediaStarted" : "mediaEnded" });
  }
});

browser.tabs.onRemoved.addListener((tabID) => {
  audibleTabs.delete(tabID);
});
