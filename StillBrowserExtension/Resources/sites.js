const SUPPORTED_HOSTS = ["meet.google.com", "teams.microsoft.com", "whereby.com"];
const SUPPORTED_DOMAINS = ["zoom.us"];
const MEETING_PHASES = ["started", "ended"];
const SPEAKER_PHASES = ["speakerStarted", "speakerEnded"];
const MAXIMUM_SPEAKER_LENGTH = 128;

export function isSupported(host) {
  if (typeof host !== "string") {
    return false;
  }
  return (
    SUPPORTED_HOSTS.includes(host) ||
    SUPPORTED_DOMAINS.some((domain) => host === domain || host.endsWith(`.${domain}`))
  );
}

export function isMeetingBoundary(phase) {
  return MEETING_PHASES.includes(phase);
}

export function meetingSignal(message) {
  if (!message || !isSupported(message.host)) {
    return null;
  }
  const { host, meetingID, phase, speaker } = message;
  if (typeof meetingID !== "string") {
    return null;
  }
  if (isMeetingBoundary(phase)) {
    return { host, meetingID, phase };
  }
  if (
    SPEAKER_PHASES.includes(phase) &&
    typeof speaker === "string" &&
    speaker.length > 0 &&
    speaker.length <= MAXIMUM_SPEAKER_LENGTH
  ) {
    return { host, meetingID, phase, speaker };
  }
  return null;
}
