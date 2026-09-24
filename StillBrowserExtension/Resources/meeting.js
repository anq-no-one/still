const extensionRuntime = (globalThis.browser ?? globalThis.chrome).runtime;
const MEETING_ID = `${location.host}${location.pathname}`;

let reportedStart = false;

function inMeeting() {
  return Boolean(
    document.querySelector('[data-call-ended="false"]') ||
      document.querySelector('[aria-label*="Leave call" i]') ||
      document.querySelector('[aria-label*="Leave meeting" i]') ||
      document.querySelector('[aria-label*="End meeting" i]')
  );
}

function report(phase) {
  extensionRuntime.sendMessage({ host: location.host, meetingID: MEETING_ID, phase });
}

function check() {
  const active = inMeeting();

  if (active && !reportedStart) {
    reportedStart = true;
    report("started");
  } else if (!active && reportedStart) {
    reportedStart = false;
    report("ended");
  }
}

setInterval(check, 2000);
window.addEventListener("pagehide", () => {
  if (reportedStart) {
    reportedStart = false;
    report("ended");
  }
});
