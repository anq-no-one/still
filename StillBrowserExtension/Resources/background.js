import { meetingSignal } from "./sites.js";

browser.runtime.onMessage.addListener((message) => {
  const signal = meetingSignal(message);
  if (signal) {
    browser.runtime.sendNativeMessage("application.id", signal);
  }
});
