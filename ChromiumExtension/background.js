import { isMeetingBoundary, meetingSignal } from "./sites.js";

const NATIVE_HOST = "com.andrii.still.meetings";

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
  }
});

chrome.tabs.onRemoved.addListener(async (tabID) => {
  const meeting = (await openMeetings())[tabID];
  if (!meeting) {
    return;
  }
  await remember(tabID, null);
  forward({ ...meeting, phase: "ended", tabID });
});
