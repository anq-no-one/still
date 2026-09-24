const extensionRuntime = (globalThis.browser ?? globalThis.chrome).runtime;
const MEETING_ID = `${location.host}${location.pathname}`;
const MEET_SPEAKING_INDICATORS = ".Oaajhc, .HX2H7, .wEsLMd, .OgVli";

const SPEAKER_READERS = {
  "meet.google.com": meetSpeakers,
};

let reportedStart = false;
let speaking = new Set();

function inMeeting() {
  return Boolean(
    document.querySelector('[data-call-ended="false"]') ||
      document.querySelector('[aria-label*="Leave call" i]') ||
      document.querySelector('[aria-label*="Leave meeting" i]') ||
      document.querySelector('[aria-label*="End meeting" i]')
  );
}

function meetTileName(tile) {
  const named = tile.querySelector("[data-self-name]");
  const text = named?.getAttribute("data-self-name") || tile.querySelector(".notranslate")?.textContent;
  return text?.trim() || null;
}

function meetSpeakers() {
  const names = new Set();
  for (const tile of document.querySelectorAll("[data-participant-id]")) {
    const isSpeaking = tile.matches(MEET_SPEAKING_INDICATORS) || tile.querySelector(MEET_SPEAKING_INDICATORS);
    const name = isSpeaking ? meetTileName(tile) : null;
    if (name) {
      names.add(name);
    }
  }
  return names;
}

function report(phase, speaker) {
  extensionRuntime.sendMessage({ host: location.host, meetingID: MEETING_ID, phase, speaker });
}

function updateSpeakers(current) {
  for (const name of speaking) {
    if (!current.has(name)) {
      report("speakerEnded", name);
    }
  }
  for (const name of current) {
    if (!speaking.has(name)) {
      report("speakerStarted", name);
    }
  }
  speaking = current;
}

function checkSpeakers() {
  const readSpeakers = SPEAKER_READERS[location.host];
  if (reportedStart && readSpeakers) {
    updateSpeakers(readSpeakers());
  }
}

function endMeeting() {
  updateSpeakers(new Set());
  reportedStart = false;
  report("ended");
}

function check() {
  const active = inMeeting();

  if (active && !reportedStart) {
    reportedStart = true;
    report("started");
  } else if (!active && reportedStart) {
    endMeeting();
  }
}

setInterval(check, 2000);
setInterval(checkSpeakers, 500);
window.addEventListener("pagehide", () => {
  if (reportedStart) {
    endMeeting();
  }
});
