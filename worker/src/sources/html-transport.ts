// HTML transport — same idea as JsonTransport, for pages instead of JSON.
// Production fetches via a browser context (PSA/CGC cert pages sit behind bot
// protection that blocks bare fetch); tests inject saved HTML fixtures.

export interface HtmlTransport {
  /** GET a URL, return the rendered HTML. Throws HtmlTransportError on non-2xx. */
  getHtml(url: string): Promise<string>;
}

export class HtmlTransportError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = "HtmlTransportError";
  }
}

export class FixtureHtmlTransport implements HtmlTransport {
  constructor(private readonly routes: Array<{ match: string; html: string; status?: number }>) {}
  async getHtml(url: string): Promise<string> {
    const hit = this.routes.find((r) => url.includes(r.match));
    if (!hit) throw new HtmlTransportError(`no fixture for ${url}`, 404);
    if (hit.status && hit.status >= 400) throw new HtmlTransportError(`fixture ${hit.status}`, hit.status);
    return hit.html;
  }
}
