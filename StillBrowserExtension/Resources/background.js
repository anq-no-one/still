// Forwards the meeting signal to Still and drops everything else. No page
// content, no tab contents, and nothing from Still comes back.

const SUPPORTED_HOSTS = [
  "meet.google.com",
  "teams.microsoft.com",
  "whereby.com",
];

function isSupported(host) {
  return SUPPORTED_HOSTS.includes(host) || host.endsWith(".zoom.us") || host === "zoom.us";
}

browser.runtime.onMessage.addListener((message) => {
  if (!message || !isSupported(message.host)) {
    return;
  }

  const { host, meetingID, phase } = message;
  if (phase !== "started" && phase !== "ended") {
    return;
  }

  browser.runtime.sendNativeMessage("application.id", { host, meetingID, phase });
});
