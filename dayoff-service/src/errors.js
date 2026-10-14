export class ServiceError extends Error {
  constructor(code, { retryAfterMs = 0 } = {}) {
    super(code);
    this.name = 'ServiceError';
    this.code = code;
    this.retryAfterMs = retryAfterMs;
  }
}

// Do not expose fetch errors, which may contain the API key in a request URL.
export function safeErrorCode(error) {
  return error instanceof ServiceError ? error.code : 'upstream_unavailable';
}
