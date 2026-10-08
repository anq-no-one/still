const SUPPORTED_HOSTS = ["meet.google.com", "teams.microsoft.com", "whereby.com"];
const SUPPORTED_DOMAINS = ["zoom.us"];
const MEETING_PHASES = ["started", "ended"];
const SPEAKER_PHASES = ["speakerStarted", "speakerEnded"];
const MAXIMUM_SPEAKER_LENGTH = 128;
const MAXIMUM_PARTICIPANTS = 100;

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
  const { host, meetingID, phase, speaker, participants } = message;
  if (typeof meetingID !== "string") {
    return null;
  }
  if (isMeetingBoundary(phase)) {
    return { host, meetingID, phase };
  }
  if (phase === "participants" && Array.isArray(participants)) {
    const names = participants
      .filter((name) => typeof name === "string" && name.length > 0 && name.length <= MAXIMUM_SPEAKER_LENGTH)
      .slice(0, MAXIMUM_PARTICIPANTS);
    return names.length > 0 ? { host, meetingID, phase, participants: names } : null;
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
