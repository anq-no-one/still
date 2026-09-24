import { isMeetingBoundary, meetingSignal } from "./sites.js";

const NATIVE_HOST = "com.andrii.still.meetings";
const audibleTabs = new Set();

function forward(signal) {
  chrome.runtime.sendNativeMessage(NATIVE_HOST, signal).catch(() => {});
}

async function openMeetings() {
  const { meetings = {} } = await chrome.storage.session.get("meetings");
  return meetings;
}

async function remember(tabID, meeting) {
  if (tabID === undefined) {
    return;
  }
  const meetings = await openMeetings();
  if (meeting) {
    meetings[tabID] = meeting;
  } else {
    delete meetings[tabID];
  }
  await chrome.storage.session.set({ meetings });
}

chrome.runtime.onMessage.addListener((message, sender) => {
  const signal = meetingSignal(message);
  if (!signal) {
    return;
  }
  const tabID = sender.tab?.id;
  forward({ ...signal, tabID });
  if (isMeetingBoundary(signal.phase)) {
    remember(tabID, signal.phase === "started" ? { host: signal.host, meetingID: signal.meetingID } : null);
    audibleTabs.clear();
  }
});

chrome.tabs.onRemoved.addListener(async (tabID) => {
  audibleTabs.delete(tabID);
  const meeting = (await openMeetings())[tabID];
  if (!meeting) {
    return;
  }
  await remember(tabID, null);
  forward({ ...meeting, phase: "ended", tabID });
});


chrome.tabs.onUpdated.addListener(async (tabID, change) => {
  if (!("audible" in change)) {
    return;
  }
  const meetings = await openMeetings();
  const [meetingTab, meeting] = Object.entries(meetings)[0] ?? [];
  if (!meeting || String(tabID) === meetingTab) {
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
    forward({ ...meeting, phase: isAudible ? "mediaStarted" : "mediaEnded", tabID });
  }
});
