const SUPPORTED_HOSTS = ["meet.google.com", "teams.microsoft.com", "whereby.com"];
const SUPPORTED_DOMAINS = ["zoom.us"];

export function isSupported(host) {
  if (typeof host !== "string") {
    return false;
  }
  return (
    SUPPORTED_HOSTS.includes(host) ||
    SUPPORTED_DOMAINS.some((domain) => host === domain || host.endsWith(`.${domain}`))
  );
}

export function meetingSignal(message) {
  if (!message || !isSupported(message.host)) {
    return null;
  }
  const { host, meetingID, phase } = message;
  if ((phase !== "started" && phase !== "ended") || typeof meetingID !== "string") {
    return null;
  }
  return { host, meetingID, phase };
}
